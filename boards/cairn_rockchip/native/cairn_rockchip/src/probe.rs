//! `cairn-rockchip-probe --rk-probe`: decode an H.264 Annex-B file through
//! [`MppDecoder`] the way the pipeline will feed it — one whole access unit
//! per packet, parameter sets in band, pts = AU index — and report what came
//! back as bounded JSON lines on stdout.
//!
//! This is a standalone binary, so it may sleep and retry; nothing here is
//! reachable from a NIF.

use std::ops::Range;
use std::path::PathBuf;
use std::process::ExitCode;
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{bail, Context as _, Result};
use serde_json::{json, Value};

use crate::mpp::{Frame, Geometry, MppDecoder, Put};

const USAGE: &str = "usage: cairn-rockchip-probe --rk-probe <annexb-file> \
[--skip-aus N] [--hold-after N] [--streams N] [--fps F]";

/// Output is at most 34 lines whatever the input: the open line, up to
/// [`INFO_CHANGE_LINES`], one line per stream and the total — or, on an
/// error, the lines before it and the error line.
const MAX_STREAMS: usize = 16;
const INFO_CHANGE_LINES: usize = 16;

/// Frames that arrive while `--hold-after`'s frame is held before it is let go.
const HOLD_FOR: u64 = 60;

/// How long after the last AU the decoder has to emit its EOS frame, and how
/// long a flat-out feed may stay full before the probe gives up.
const DEADLINE: Duration = Duration::from_secs(5);
const RETRY_SLEEP: Duration = Duration::from_millis(1);

#[derive(Debug)]
pub struct Args {
    pub file: PathBuf,
    pub skip_aus: usize,
    /// 1-based: the Nth frame returned.
    pub hold_after: Option<u64>,
    pub streams: usize,
    pub fps: Option<f64>,
}

pub fn parse(args: &[String]) -> Result<Args, String> {
    let mut parsed = Args {
        file: PathBuf::new(),
        skip_aus: 0,
        hold_after: None,
        streams: 1,
        fps: None,
    };
    let mut it = args.iter();
    if it.next().is_none_or(|first| first != "--rk-probe") {
        return Err("--rk-probe comes first".into());
    }
    parsed.file = it.next().ok_or("--rk-probe needs a file")?.into();
    while let Some(flag) = it.next() {
        let mut value = || it.next().ok_or_else(|| format!("{flag} needs a value"));
        match flag.as_str() {
            "--skip-aus" => parsed.skip_aus = number(flag, value()?)?,
            "--hold-after" => match number(flag, value()?)? {
                0 => return Err("--hold-after counts from 1".into()),
                n => parsed.hold_after = Some(n),
            },
            "--streams" => match number(flag, value()?)? {
                n @ 1..=MAX_STREAMS => parsed.streams = n,
                _ => return Err(format!("--streams is 1 to {MAX_STREAMS}")),
            },
            "--fps" => match number::<f64>(flag, value()?)? {
                f if (0.1..=1000.0).contains(&f) => parsed.fps = Some(f),
                _ => return Err("--fps is 0.1 to 1000".into()),
            },
            other => return Err(format!("unknown argument {other:?}")),
        }
    }
    Ok(parsed)
}

fn number<T: std::str::FromStr>(flag: &str, v: &str) -> Result<T, String> {
    v.parse()
        .map_err(|_| format!("{flag}: {v:?} is not a number"))
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Au {
    pub bytes: Range<usize>,
    pub idr: bool,
}

/// Access units by H.264's first-NAL rules (7.4.1.2.3), as far as a
/// single-layer camera stream needs: an AUD, or an SEI/SPS/PPS after the
/// AU's first VCL NAL, or a slice with `first_mb_in_slice` 0 after one,
/// starts the next. A 4-byte start code's leading zero goes with the AU it
/// opens; bytes before the first start code are dropped.
pub fn split_aus(data: &[u8]) -> Vec<Au> {
    let mut aus: Vec<Au> = Vec::new();
    let mut seen_vcl = false;
    let mut i = 0;
    while i + 3 < data.len() {
        if data[i..i + 3] != [0, 0, 1] {
            i += 1;
            continue;
        }
        let at = if i > 0 && data[i - 1] == 0 { i - 1 } else { i };
        let header = i + 3;
        i = header;
        let ty = data[header] & 0x1f;
        let vcl = ty == 1 || ty == 5;
        // ue(v) 0 is a single 1 bit, so the slice header's first byte has its
        // top bit set exactly when `first_mb_in_slice` is 0. A start code
        // straight after the header byte reads as a 0 here.
        let first_slice = data.get(header + 1).is_some_and(|b| b & 0x80 != 0);
        if aus.is_empty() || ty == 9 || (seen_vcl && (matches!(ty, 6..=8) || (vcl && first_slice)))
        {
            if let Some(last) = aus.last_mut() {
                last.bytes.end = at;
            }
            aus.push(Au {
                bytes: at..data.len(),
                idr: false,
            });
            seen_vcl = false;
        }
        let au = aus.last_mut().expect("pushed above");
        au.idr |= ty == 5;
        seen_vcl |= vcl;
    }
    aus
}

/// `MemAvailable` and `CmaFree` in kB, each if the kernel reports it.
fn meminfo() -> [Option<u64>; 2] {
    let text = std::fs::read_to_string("/proc/meminfo").unwrap_or_default();
    ["MemAvailable:", "CmaFree:"].map(|name| {
        let line = text.lines().find_map(|line| line.strip_prefix(name))?;
        line.split_whitespace().next()?.parse().ok()
    })
}

fn geometry_json(g: Geometry) -> Value {
    json!({
        "width": g.width, "height": g.height, "hor_stride": g.hor_stride,
        "ver_stride": g.ver_stride, "buf_size": g.buf_size,
    })
}

#[derive(Default)]
struct Stream {
    fed: u64,
    last_fed: i64,
    dropped_aus: u64,
    returned: u64,
    first_frame_pts: Option<i64>,
    nv12: bool,
    max_lag: i64,
    max_put_us: u128,
    max_poll_us: u128,
    held: Option<Frame>,
    held_pts: Option<i64>,
    /// Whether a frame came back on the held frame's dma-buf while it was held.
    held_fd_reused: bool,
    frames_while_held: u64,
    hold_reached: bool,
    info_changes: Vec<Value>,
}

impl Stream {
    /// Takes frames until `next_frame` returns none, which it also does at
    /// its per-call bound: what is still queued comes out on the next drain.
    fn drain(&mut self, decoder: &mut MppDecoder, hold_after: Option<u64>) -> Result<()> {
        loop {
            let changes = decoder.stats().info_changes;
            let polled = Instant::now();
            let frame = decoder.next_frame()?;
            self.max_poll_us = self.max_poll_us.max(polled.elapsed().as_micros());
            if decoder.stats().info_changes != changes
                && self.info_changes.len() < INFO_CHANGE_LINES
            {
                let mut line = decoder.geometry().map_or(json!({}), geometry_json);
                line["fed_au"] = self.last_fed.into();
                self.info_changes.push(line);
            }
            let Some(frame) = frame else {
                return Ok(());
            };
            self.returned += 1;
            self.first_frame_pts.get_or_insert(frame.pts());
            self.nv12 = (self.returned == 1 || self.nv12) && frame.is_nv12();
            self.max_lag = self.max_lag.max(self.last_fed - frame.pts());
            if let Some(held) = &self.held {
                self.held_fd_reused |= frame.fd() == held.fd();
                self.frames_while_held += 1;
                if self.frames_while_held == HOLD_FOR {
                    self.held = None;
                    self.hold_reached = true;
                }
            } else if hold_after == Some(self.returned) {
                self.held_pts = Some(frame.pts());
                self.held = Some(frame);
            }
        }
    }
}

/// A stream's summary line, and its info-change lines.
fn decode_stream(data: &[u8], aus: &[Au], args: &Args) -> Result<(Value, Vec<Value>)> {
    let mut decoder = MppDecoder::open()?;
    let mut s = Stream::default();
    let started = Instant::now();
    let period = args.fps.map(|fps| Duration::from_secs_f64(1.0 / fps));
    for (index, au) in aus.iter().enumerate().skip(args.skip_aus) {
        let pts = index as i64;
        if let Some(period) = period {
            let due = started + period.mul_f64(s.fed as f64);
            while Instant::now() < due {
                s.drain(&mut decoder, args.hold_after)?;
                thread::sleep(RETRY_SLEEP.min(due.saturating_duration_since(Instant::now())));
            }
        }
        s.fed += 1;
        let full_since = Instant::now();
        loop {
            let put = Instant::now();
            let result = decoder.put(&data[au.bytes.clone()], pts)?;
            s.max_put_us = s.max_put_us.max(put.elapsed().as_micros());
            if result == Put::Accepted {
                s.last_fed = pts;
                break;
            }
            if period.is_some() {
                s.dropped_aus += 1;
                break;
            }
            // Sleeping and retrying is allowed only because this is a
            // standalone binary; a NIF's feed drops the AU, as `--fps` does.
            s.drain(&mut decoder, args.hold_after)?;
            if full_since.elapsed() > DEADLINE {
                bail!("MPP stayed full for {DEADLINE:?} at AU {index}");
            }
            thread::sleep(RETRY_SLEEP);
        }
        s.drain(&mut decoder, args.hold_after)?;
    }
    let finishing = Instant::now();
    while !decoder.eos() && finishing.elapsed() < DEADLINE {
        decoder.finish()?;
        s.drain(&mut decoder, args.hold_after)?;
        thread::sleep(RETRY_SLEEP);
    }
    let elapsed = started.elapsed();
    let stats = decoder.stats();
    let first_idr_au = (args.skip_aus..aus.len()).find(|&index| aus[index].idr);
    let summary = json!({
        "event": "stream", "aus": s.fed, "accepted": stats.accepted,
        "input_full": stats.input_full, "dropped_aus": s.dropped_aus,
        "frames": stats.frames, "errinfo": stats.errinfo, "discarded": stats.discarded,
        "info_changes": stats.info_changes, "first_idr_au": first_idr_au,
        "first_frame_pts": s.first_frame_pts,
        "geometry": decoder.geometry().map(geometry_json),
        "nv12": s.returned > 0 && s.nv12, "max_lag_aus": s.max_lag,
        "elapsed_ms": elapsed.as_millis(),
        "fps": stats.frames as f64 / elapsed.as_secs_f64(),
        "max_put_us": s.max_put_us, "max_poll_us": s.max_poll_us,
        "eos": decoder.eos(),
        "held_pts": s.held_pts, "frames_while_held": s.frames_while_held,
        "held_fd_reused": s.held_pts.map(|_| s.held_fd_reused),
        "hold_reached": s.hold_reached,
    });
    Ok((summary, s.info_changes))
}

pub fn run(args: &[String]) -> ExitCode {
    let args = match parse(args) {
        Ok(args) => args,
        Err(msg) => {
            eprintln!("{msg}\n{USAGE}");
            return ExitCode::from(2);
        }
    };
    let result = probe(&args);
    // Every decoder is gone by now; their teardown failures are only queued.
    cairn_detect::log::drain();
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            println!(
                "{}",
                json!({"event": "error", "message": format!("{err:#}")})
            );
            ExitCode::FAILURE
        }
    }
}

fn probe(args: &Args) -> Result<()> {
    let shown = args.file.display();
    let data = std::fs::read(&args.file).with_context(|| format!("reading {shown}"))?;
    let aus = split_aus(&data);
    if args.skip_aus >= aus.len() {
        bail!("{shown} has {} access units, all skipped", aus.len());
    }
    println!(
        "{}",
        json!({
            "event": "open", "file": shown.to_string(), "bytes": data.len(),
            "aus": aus.len(), "idr_aus": aus.iter().filter(|au| au.idr).count(),
            "skip_aus": args.skip_aus, "streams": args.streams, "fps": args.fps,
            "hold_after": args.hold_after,
        })
    );
    let started = Instant::now();
    let (mut start, mut min) = (meminfo(), meminfo());
    let results: Vec<_> = thread::scope(|scope| {
        let handles: Vec<_> = (0..args.streams)
            .map(|_| scope.spawn(|| decode_stream(&data, &aus, args)))
            .collect();
        loop {
            let done = handles.iter().all(|h| h.is_finished());
            for (i, now) in meminfo().into_iter().enumerate() {
                start[i] = start[i].or(now);
                min[i] = min[i].into_iter().chain(now).min();
            }
            if done {
                break;
            }
            thread::sleep(Duration::from_millis(50));
        }
        handles
            .into_iter()
            .map(|h| h.join().unwrap_or_else(|_| bail!("the stream panicked")))
            .collect()
    });
    let wall = started.elapsed();
    let (mut frames, mut changes, mut printed) = (0, 0, 0);
    for (stream, result) in results.into_iter().enumerate() {
        let (mut summary, lines) = result.with_context(|| format!("stream {stream}"))?;
        for mut line in lines.into_iter().take(INFO_CHANGE_LINES - printed) {
            printed += 1;
            line["event"] = "info_change".into();
            line["stream"] = stream.into();
            println!("{line}");
        }
        frames += summary["frames"].as_u64().unwrap_or(0);
        changes += summary["info_changes"].as_u64().unwrap_or(0);
        summary["stream"] = stream.into();
        println!("{summary}");
    }
    let total = json!({
        "event": "total", "streams": args.streams, "frames": frames,
        "wall_fps": frames as f64 / wall.as_secs_f64(),
        "info_changes_unprinted": changes - printed as u64,
        "mem_available_kb": {"start": start[0], "min": min[0]},
        "cma_free_kb": {"start": start[1], "min": min[1]},
    });
    println!("{total}");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A NAL with a 4-byte start code: header byte, then payload.
    fn nal(ty: u8, payload: &[u8]) -> Vec<u8> {
        let mut bytes = vec![0, 0, 0, 1, 0x60 | ty];
        bytes.extend_from_slice(payload);
        bytes
    }

    fn slice(ty: u8, first: bool) -> Vec<u8> {
        nal(ty, &[if first { 0x88 } else { 0x40 }, 0x11])
    }

    fn args(list: &[&str]) -> Result<Args, String> {
        parse(&list.iter().map(|s| s.to_string()).collect::<Vec<_>>())
    }

    #[test]
    fn arguments_parse_and_refuse() {
        let parsed = args(&["--rk-probe", "f.h264", "--skip-aus", "3", "--streams", "2"]).unwrap();
        let fields = (
            parsed.file,
            parsed.skip_aus,
            parsed.streams,
            parsed.hold_after,
        );
        assert_eq!(fields, ("f.h264".into(), 3, 2, None));
        let parsed = args(&["--rk-probe", "f", "--fps", "12.5", "--hold-after", "4"]).unwrap();
        assert_eq!((parsed.fps, parsed.hold_after), (Some(12.5), Some(4)));
        for (bad, says) in [
            (&["--skip-aus", "1", "--rk-probe", "f"][..], "comes first"),
            (&["--rk-probe"], "needs a file"),
            (&["--rk-probe", "f", "--streams"], "needs a value"),
            (&["--rk-probe", "f", "--streams", "0"], "1 to 16"),
            (&["--rk-probe", "f", "--fps", "0"], "0.1 to 1000"),
            (&["--rk-probe", "f", "--fps", "1e-20"], "0.1 to 1000"),
            (&["--rk-probe", "f", "--fps", "1001"], "0.1 to 1000"),
            (&["--rk-probe", "f", "--hold-after", "0"], "from 1"),
            (&["--rk-probe", "f", "--skip-aus", "x"], "not a number"),
            (&["--rk-probe", "f", "--model", "m"], "unknown"),
        ] {
            assert!(args(bad).unwrap_err().contains(says), "{bad:?}");
        }
    }

    #[test]
    fn access_units_split_at_parameter_sets_auds_and_first_slices() {
        let sps_pps_idr = [nal(7, &[0x42]), nal(8, &[0xce]), slice(5, true)].concat();
        // A two-slice P picture, then an AUD-led one with a 3-byte start code.
        let two_slices = [slice(1, true), slice(1, false)].concat();
        let aud_led = [vec![0, 0, 1, 0x09, 0xf0], slice(1, true)].concat();
        let sei_led = [nal(6, &[0x05]), slice(1, true)].concat();
        // The last is a second file appended: its SPS starts a new AU.
        let aus = [
            sps_pps_idr.clone(),
            two_slices,
            aud_led,
            sei_led,
            sps_pps_idr,
        ];
        let file = [&[0xff][..], &aus.concat()].concat();
        let mut at = 1;
        let expected: Vec<Au> = (aus.iter().zip([true, false, false, false, true]))
            .map(|(au, idr)| {
                at += au.len();
                Au {
                    bytes: at - au.len()..at,
                    idr,
                }
            })
            .collect();
        assert_eq!(split_aus(&file), expected, "leading garbage dropped");
    }

    #[test]
    fn a_file_without_start_codes_has_no_access_units() {
        assert!(split_aus(b"not h264 at all").is_empty());
        assert!(split_aus(&[0, 0, 1]).is_empty());
    }
}
