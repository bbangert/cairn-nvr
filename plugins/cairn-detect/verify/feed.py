#!/usr/bin/env python3
"""Feed a recorded fixture clip to a UDP port as RTP, exactly like Cairn does.

Cairn's own ffmpeg invocation lives in lib/cairn/ffmpeg_port.ex
(Cairn.FfmpegPort.build_argv/4). For a local-file source (the `true ->`
branch of its `input_opts` cond, used for dev/fixture loops) it builds:

    ffmpeg -nostdin -nostats -loglevel warning \
      -re -stream_loop -1 -i <path> \
      -map 0:v -c:v copy -bsf:v h264_mp4toannexb \
      -f rtp -payload_type 96 rtp://127.0.0.1:<plugin_port>
      [... two more -map/-f rtp outputs for fmp4 + the WebRTC hub port,
           which a plugin never sees and this harness does not reproduce]

Notably:
  - `-bsf:v h264_mp4toannexb` is NOT optional. Cairn's comment on that line
    explains why: RTP consumers need SPS/PPS in-band, and an mp4-muxed
    source (like these fixture clips) keeps them in extradata only. Skip
    this bitstream filter and a decoder joining mid-stream (the normal
    case per the plugin contract) may never see parameter sets at all.
  - There is no `-an` in Cairn's real argv. It doesn't need one: `-map 0:v`
    already selects only the video stream, so no audio track ever reaches
    the RTP muxer (RTP/AVP payload type 96 here is video-only anyway). We
    keep `-map 0:v -c:v copy` to match Cairn exactly rather than relying on
    `-an` to do the same job a different way.
  - Cairn passes `-stream_loop -1` unconditionally for file sources; this
    harness exposes it as --loops so you can also do a bounded run.

This script reproduces the single RTP output a plugin actually receives.
"""
import argparse
import glob
import os
import shlex
import signal
import subprocess
import sys

DEFAULT_CLIP_DIR = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "..",
    "data", "events", "reolink_main",
)


def newest_clip(clip_dir: str) -> str:
    clips = glob.glob(os.path.join(clip_dir, "*.mp4"))
    if not clips:
        raise SystemExit(f"no .mp4 fixtures found under {clip_dir}")
    return max(clips, key=os.path.getmtime)


def build_argv(clip: str, port: int, loops: int) -> list:
    return [
        "ffmpeg",
        "-nostdin", "-nostats", "-loglevel", "warning",
        "-re", "-stream_loop", str(loops),
        "-i", clip,
        "-map", "0:v",
        "-c:v", "copy",
        "-bsf:v", "h264_mp4toannexb",
        "-f", "rtp", "-payload_type", "96",
        f"rtp://127.0.0.1:{port}",
    ]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--clip", default=None,
                     help="fixture clip path (default: newest .mp4 in data/events/reolink_main)")
    ap.add_argument("--port", type=int, required=True, help="destination UDP port on 127.0.0.1")
    ap.add_argument("--loops", type=int, default=-1,
                     help="ffmpeg -stream_loop value; -1 = infinite (default), 0 = play once")
    ap.add_argument("--duration", type=float, default=None,
                     help="kill ffmpeg after this many seconds (default: run until stopped)")
    args = ap.parse_args()

    clip = args.clip or newest_clip(DEFAULT_CLIP_DIR)
    if not os.path.isfile(clip):
        raise SystemExit(f"clip not found: {clip}")

    argv = build_argv(clip, args.port, args.loops)
    print("+ " + shlex.join(argv), file=sys.stderr)

    # New session/process group so signals delivered to us don't also land
    # on ffmpeg out of order with our own handling below.
    proc = subprocess.Popen(argv, start_new_session=True)  # stderr inherited: streams through as-is

    stopping = False

    def _stop(signum, _frame):
        nonlocal stopping
        if stopping:
            return
        stopping = True
        print(f"feed.py: got signal {signum}, stopping ffmpeg...", file=sys.stderr)
        try:
            proc.terminate()
        except ProcessLookupError:
            pass

    signal.signal(signal.SIGINT, _stop)
    signal.signal(signal.SIGTERM, _stop)

    if args.duration is not None:
        try:
            proc.wait(timeout=args.duration)
        except subprocess.TimeoutExpired:
            print(f"feed.py: duration {args.duration}s elapsed, stopping ffmpeg...", file=sys.stderr)
            stopping = True
            proc.terminate()

    # Wait until ffmpeg exits. Only once a stop was requested (signal or
    # --duration) does a grace period apply — a healthy feed runs forever.
    grace_left = None
    while proc.poll() is None:
        try:
            proc.wait(timeout=1)
        except subprocess.TimeoutExpired:
            if not stopping:
                continue
            grace_left = 10 if grace_left is None else grace_left - 1
            if grace_left <= 0:
                print("feed.py: ffmpeg did not exit after terminate, killing", file=sys.stderr)
                proc.kill()
                proc.wait()

    # 0 only for intentional stops (signal or elapsed --duration, both set
    # `stopping`); an early ffmpeg death propagates its real exit code so
    # harness failures aren't masked.
    return 0 if stopping else (proc.returncode or 0)


if __name__ == "__main__":
    sys.exit(main())
