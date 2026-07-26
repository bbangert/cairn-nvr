//! Opening the H.264 RTP feed Cairn points at us.

use std::ffi::CString;
use std::fs;
use std::io::{self, Read, Write};
#[cfg(unix)]
use std::os::unix::fs::OpenOptionsExt;
use std::path::PathBuf;
use std::thread::sleep;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{anyhow, Context, Result};
use rsmpeg::avformat::{AVFormatContextInput, AVInputFormat};
use rsmpeg::avutil::AVDictionary;

const OPEN_RETRY: Duration = Duration::from_secs(5);
const MAX_OPEN_ATTEMPTS: u32 = 12;

/// Raw RTP has no session negotiation; feed the demuxer a static SDP.
///
/// The demuxer also binds `port + 1` for RTCP even though Cairn never sends
/// any — that port is reserved for us (see `Cairn.UDPPorts`). ffmpeg ignores
/// an `a=rtcp:` override here, so the reservation has to hold.
pub fn sdp_for(port: u16) -> String {
    format!(
        "v=0\r\n\
         o=- 0 0 IN IP4 127.0.0.1\r\n\
         s=cairn\r\n\
         c=IN IP4 127.0.0.1\r\n\
         t=0 0\r\n\
         m=video {port} RTP/AVP 96\r\n\
         a=rtpmap:96 H264/90000\r\n"
    )
}

fn stream_options() -> AVDictionary {
    // The dictionary is consumed by avformat_open_input, so this is rebuilt
    // per attempt.
    AVDictionary::new(c"protocol_whitelist", c"file,udp,rtp", 0)
        .set(c"fflags", c"nobuffer", 0)
        // Cairn's ffmpeg puts SPS/PPS in-band next to keyframes, and a plugin
        // starting mid-stream lands between them with nothing to probe. The
        // defaults give up in milliseconds ("Invalid data found"); these let
        // the probe wait out a GOP instead.
        .set(c"analyzeduration", c"10000000", 0) // µs
        .set(c"probesize", c"5000000", 0)
        // A 2560x1920 camera pushes ~34 Mbps, and one keyframe is a burst of
        // several hundred loopback packets back to back. The 208 KB default
        // receive buffer overflows mid-burst, which shows up as a corrupt
        // probe ("Invalid data found") or torn frames later. 4 MB is
        // net.core.rmem_max on a stock kernel; raise that first if you still
        // see RcvbufErrors climb in /proc/net/snmp.
        .set(c"buffer_size", c"4194304", 0)
        // The SDP's `c=IN IP4 127.0.0.1` does not constrain the bind: without
        // this the udp protocol listens on 0.0.0.0 and anything that can route
        // to the host can inject frames into a camera's detector. Moves both
        // the RTP port and the RTCP port to loopback.
        .set(c"localaddr", c"127.0.0.1", 0)
        // Socket read timeout, matching the Python reference's `timeout=30`.
        // Without it a port that never receives a byte blocks forever inside
        // the probe (so the retry loop below never gets a second attempt) and
        // a mid-run silence parks `read_packet` instead of exiting for Cairn
        // to restart.
        .set(c"timeout", c"30000000", 0) // µs
}

/// Temp SDP file, removed once the stream is open (or given up on).
struct SdpFile {
    path: PathBuf,
}

impl SdpFile {
    /// Create with an unpredictable name and `O_EXCL`.
    ///
    /// A guessable path in a shared `/tmp` lets another local user pre-place a
    /// symlink and have this process truncate a file on their behalf.
    fn write(port: u16) -> Result<Self> {
        let dir = std::env::temp_dir();
        let mut last_err = None;
        for _ in 0..8 {
            let path = dir.join(format!("cairn-detect-{port}-{}.sdp", random_suffix()));
            let mut options = fs::OpenOptions::new();
            options.write(true).create_new(true);
            #[cfg(unix)]
            options.mode(0o600);
            match options.open(&path) {
                Ok(mut file) => {
                    file.write_all(sdp_for(port).as_bytes())
                        .with_context(|| format!("writing sdp to {}", path.display()))?;
                    return Ok(Self { path });
                }
                Err(e) if e.kind() == io::ErrorKind::AlreadyExists => last_err = Some(e),
                Err(e) => {
                    return Err(e).with_context(|| format!("creating sdp at {}", path.display()))
                }
            }
        }
        Err(last_err.expect("loop only exits early on success or a hard error"))
            .context("could not create a unique sdp file")
    }
}

fn random_suffix() -> String {
    let mut bytes = [0u8; 8];
    if let Ok(mut urandom) = fs::File::open("/dev/urandom") {
        if urandom.read_exact(&mut bytes).is_ok() {
            return bytes.iter().map(|b| format!("{b:02x}")).collect();
        }
    }
    // Falls back to something merely unlikely to collide; the O_EXCL retry
    // above is what actually guarantees we never open someone else's file.
    format!(
        "{}-{:x}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.subsec_nanos())
            .unwrap_or(0)
    )
}

impl Drop for SdpFile {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

/// Open the RTP feed, waiting out the gap to the next keyframe.
///
/// Joining between keyframes is routine (Cairn starts us alongside ffmpeg,
/// and loading the ONNX model takes long enough to miss the opening parameter
/// sets). Retrying in-process beats exiting: a restart would just land in the
/// same gap, one backoff later. We do still give up eventually so a genuinely
/// dead port surfaces as a plugin crash in Cairn's log rather than a silent
/// spin.
pub fn open_stream(port: u16) -> Result<AVFormatContextInput> {
    open_stream_within(port, MAX_OPEN_ATTEMPTS)
}

/// One open attempt, for callers that own their own retry policy.
///
/// Multiplexed mode re-opens a dark member forever on its own backoff
/// (`multiplex::stream_loop`), so it must not also pay the 12x5s budget —
/// nor log a per-attempt line for every cycle of a camera that is simply
/// stopped.
pub fn open_stream_once(port: u16) -> Result<AVFormatContextInput> {
    open_stream_within(port, 1)
}

fn open_stream_within(port: u16, max_attempts: u32) -> Result<AVFormatContextInput> {
    let sdp = SdpFile::write(port)?;
    let url = CString::new(sdp.path.to_string_lossy().as_bytes())
        .context("sdp path contains a NUL byte")?;
    let format = AVInputFormat::find(c"sdp").ok_or_else(|| {
        anyhow!("libavformat has no sdp demuxer; this build of FFmpeg cannot read RTP")
    })?;

    let mut last_error = None;
    for attempt in 1..=max_attempts {
        let mut options = Some(stream_options());
        match AVFormatContextInput::builder()
            .url(&url)
            .format(&format)
            .options(&mut options)
            .open()
        {
            Ok(input) => return Ok(input),
            Err(e) => {
                if attempt < max_attempts {
                    eprintln!(
                        "stream open attempt {attempt}/{max_attempts} failed ({e}); waiting for a keyframe"
                    );
                    sleep(OPEN_RETRY);
                }
                last_error = Some(e);
            }
        }
    }
    Err(anyhow!(
        "no decodable stream on udp port {port} after {max_attempts} attempts: {}",
        last_error.expect("a failed open always records its error")
    ))
}

#[cfg(test)]
mod tests {
    use std::ffi::CStr;

    use super::*;

    #[test]
    fn sdp_matches_the_reference_session() {
        assert_eq!(
            sdp_for(17000),
            "v=0\r\n\
             o=- 0 0 IN IP4 127.0.0.1\r\n\
             s=cairn\r\n\
             c=IN IP4 127.0.0.1\r\n\
             t=0 0\r\n\
             m=video 17000 RTP/AVP 96\r\n\
             a=rtpmap:96 H264/90000\r\n"
        );
    }

    #[test]
    fn sdp_file_is_removed_on_drop() {
        let sdp = SdpFile::write(17002).unwrap();
        let path = sdp.path.clone();
        assert!(fs::read_to_string(&path).unwrap().contains("m=video 17002"));
        drop(sdp);
        assert!(!path.exists());
    }

    #[test]
    fn sdp_files_do_not_collide_or_reuse_a_name() {
        let a = SdpFile::write(17004).unwrap();
        let b = SdpFile::write(17004).unwrap();
        assert_ne!(a.path, b.path);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = fs::metadata(&a.path).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o600, "sdp must not be world-readable");
        }
    }

    #[test]
    fn stream_options_pin_the_socket_and_bound_the_read() {
        let options = stream_options();
        let get = |key: &CStr| {
            options
                .get(key, None, 0)
                .map(|e| e.value().to_string_lossy().into_owned())
        };
        assert_eq!(get(c"localaddr").as_deref(), Some("127.0.0.1"));
        assert_eq!(get(c"timeout").as_deref(), Some("30000000"));
        assert_eq!(get(c"protocol_whitelist").as_deref(), Some("file,udp,rtp"));
    }
}
