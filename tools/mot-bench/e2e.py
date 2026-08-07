#!/usr/bin/env python3
"""Phase-6 end-to-end MOT harness: gt frames -> real plugin -> real tracker -> score.

Unlike `mix cairn.mot.track` (tracker-only, replays a sequence's public
detections with no pixels involved), this drives the *real* detector and
embedder: it re-encodes a gt sequence's frames into an mp4, feeds it as RTP
to a running `cairn-detect` exactly like Cairn does, captures its ndjson
output, replays that capture through `mix cairn.mot.ndjson` (the real
`Cairn.PluginProtocol` -> `Cairn.Tracker`), and scores the result with
score.py.

    cd tools/mot-bench
    python3 e2e.py --seqs data/mot17_img/train/MOT17-04-SDP \\
      --tag yolox-nano --model ../../plugins/cairn-detect/yolox_nano.onnx \\
      --labels ../../plugins/cairn-detect/coco.names \\
      --embedder-model ../../plugins/cairn-detect/osnet_x0_25.onnx \\
      --bbd --oru --benchmark MOT17

Every artifact is cached and skip-if-exists, so a killed run resumes where it
stopped: the encoded video (data/e2e/videos/<Seq>.mp4), the plugin capture
(data/e2e/captures/<Seq>-<tag>.ndjson — the expensive one, a real-time feed),
and the tracker prediction (data/preds/e2e/<tag>/<Seq>.txt).

Sequences run SERIALLY: a real-time RTP feed and the plugin listening for it
share one UDP port for the whole run, so two sequences at once would race on
it.
"""
from __future__ import annotations

import argparse
import json
import re
import shlex
import subprocess
import threading
import time
from collections import deque
from pathlib import Path

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent.parent

DEFAULT_PLUGIN_BIN = REPO / "plugins" / "cairn-detect" / "target" / "release" / "cairn-detect"

# Anything that becomes a path component (--tag, seqinfo `name`, a sequence
# dir's basename) must match this and must not contain ".." -- mirrors
# score.py:255's identical guard (both scripts build dirs under `data/` from
# these values, and score.py's comment explains why "..":
# score.py builds `data/work/<tracker>-<benchmark>-<split>/` and rmtree's it).
PATH_COMPONENT_RE = re.compile(r"[A-Za-z0-9._-]+")


def valid_path_component(value: str) -> bool:
    return bool(PATH_COMPONENT_RE.fullmatch(value)) and ".." not in value


# How long to wait for "cairn-detect up:" on the plugin's stderr before
# giving up. Model load time is the model's business (a 3 MB yolox_nano and
# a 108 MB rfdetr are not the same wait) -- generous on purpose.
PLUGIN_STARTUP_TIMEOUT_S = 180

# Cairn's own control line, replayed verbatim by hand here (see
# plugins/cairn-detect/verify/README.md): the plugin emits no detections
# until it has a stream epoch, and EOF on stdin exits it -- so stdin is kept
# open for the whole run and closed only once the feed is done.
CAMERA_ID = "test"
STREAM_EPOCH = "01K0E2EEPOCH000000000000000"


def tail(text: str, n: int = 2000) -> str:
    return (text or "")[-n:]


def fmt_rate(fps: float) -> str:
    """Render a frame rate for ffmpeg -framerate: no trailing ".0" when whole."""
    return str(int(fps)) if fps == int(fps) else str(fps)


def parse_seqinfo(seq_dir: Path) -> dict:
    path = seq_dir / "seqinfo.ini"
    if not path.exists():
        raise SystemExit(f"missing seqinfo.ini in {seq_dir}")

    fields: dict[str, str] = {}
    for line in path.read_text().splitlines():
        key, sep, value = line.partition("=")
        if sep:
            fields[key.strip()] = value.strip()

    required = ["name", "frameRate", "seqLength", "imWidth", "imHeight"]
    missing = [k for k in required if k not in fields]
    if missing:
        raise SystemExit(f"{path}: missing seqinfo fields {missing}")

    return {
        "name": fields["name"],
        "frame_rate": float(fields["frameRate"]),
        "seq_length": int(fields["seqLength"]),
        "im_width": int(fields["imWidth"]),
        "im_height": int(fields["imHeight"]),
    }


def detect_img_pattern(img1_dir: Path) -> str:
    """Sniff the zero-padded numbering width and extension of img1/*, rather
    than assuming MOT17's 6-digit 000001.jpg -- other sequence sources may
    pad differently."""
    imgs = sorted(
        f for f in img1_dir.iterdir() if f.stem.isdigit() and f.suffix.lower() in (".jpg", ".jpeg", ".png")
    )
    if not imgs:
        raise SystemExit(f"no numbered image files (NNNNNN.jpg) found in {img1_dir}")
    width = len(imgs[0].stem)
    return f"%0{width}d{imgs[0].suffix}"


def build_video(seq_dir: Path, seqinfo: dict, videos_dir: Path) -> Path:
    """Step 1: gt frames -> cached mp4. Skips the encode if the cache exists;
    for a sequence with no img1/ (e.g. PersonPath22, own-clips), uses a
    sibling mp4 directly instead of encoding anything.

    Sibling-clip contract (see OWN-CLIPS.md): given seq dir basename
    `<dir>` (e.g. `OWN-<name>` for own-clips), try in order:
      (a) `<seq_dir>/../../clips/<name>.mp4`, where `<name>` is `<dir>`
          with a leading "OWN-" stripped -- the own-clips layout,
          `~/cairn-clips/clips/<name>.mp4` next to `~/cairn-clips/gt/OWN-<name>/`.
      (b) `<seq_dir>/../<dir>.mp4` -- a video dropped next to the gt dir
          under its own exact name, no prefix-stripping.
    """
    name = seqinfo["name"]
    img1_dir = seq_dir / "img1"

    if not img1_dir.is_dir():
        dir_name = seq_dir.name
        stripped = dir_name[len("OWN-"):] if dir_name.startswith("OWN-") else dir_name
        candidates = [
            seq_dir.parent.parent / "clips" / f"{stripped}.mp4",
            seq_dir.parent / f"{dir_name}.mp4",
        ]
        for candidate in candidates:
            if candidate.is_file():
                print(f"[{name}] video: no img1/, using sibling mp4 directly: {candidate}")
                return candidate
        tried = "\n  ".join(str(c) for c in candidates)
        raise SystemExit(
            f"[{name}] no img1/ under {seq_dir} and no sibling video found. Tried:\n  {tried}"
        )

    out_path = videos_dir / f"{name}.mp4"
    if out_path.exists():
        print(f"[{name}] video: cached at {out_path}")
        return out_path

    videos_dir.mkdir(parents=True, exist_ok=True)
    pattern = detect_img_pattern(img1_dir)
    fps = seqinfo["frame_rate"]
    gop = max(1, round(fps))
    # Keep the real ".mp4" as the final extension (not ".part") -- ffmpeg
    # picks its output muxer from the destination's extension, so a
    # ".mp4.part" tmp name fails at "Unable to find a suitable output format".
    tmp = out_path.with_name(out_path.stem + ".part" + out_path.suffix)

    cmd = [
        "ffmpeg", "-y", "-nostdin", "-loglevel", "error",
        "-framerate", fmt_rate(fps),
        "-i", str(img1_dir / pattern),
        "-c:v", "libx264", "-preset", "veryfast", "-crf", "20",
        "-pix_fmt", "yuv420p", "-g", str(gop), "-bf", "0",
        str(tmp),
    ]
    print(f"[{name}] video: encoding {img1_dir}/{pattern} @ {fps}fps -> {out_path}")
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        tmp.unlink(missing_ok=True)
        raise SystemExit(f"[{name}] ffmpeg encode failed:\n{tail(result.stderr)}")
    tmp.rename(out_path)
    print(f"[{name}] video: built {out_path}")
    return out_path


def video_duration_s(video):
    """The container-reported duration in seconds, or None if ffprobe balks."""
    try:
        out = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration",
             "-of", "csv=p=0", str(video)],
            capture_output=True, text=True, timeout=30)
        return float(out.stdout.strip())
    except Exception:
        return None


def run_plugin_and_feed(args, seq_name: str, seqinfo: dict, video_path: Path, capture_path: Path) -> None:
    """Steps 2 + 3: spawn the plugin, hand it the control line, wait for it
    to come up, feed the video as real-time RTP once, then close it down."""
    port = args.udp_port
    tmp_capture = capture_path.with_suffix(capture_path.suffix + ".part")

    plugin_cmd = [
        str(args.plugin_bin),
        "--model", str(args.model),
        "--labels", str(args.labels),
        "--camera-id", CAMERA_ID,
        "--udp-port", str(port),
        "--min-score-json", "{}",
        "--sample-fps", str(args.sample_fps),
    ]
    if args.embedder_model:
        plugin_cmd += ["--embedder-model", str(args.embedder_model)]

    print(f"[{seq_name}] plugin: {shlex.join(plugin_cmd)}")
    proc = subprocess.Popen(
        plugin_cmd,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )

    control_line = json.dumps(
        {
            "spec": "cairn.plugin",
            "version": 1,
            "type": "stream.started",
            "camera_id": CAMERA_ID,
            "stream_epoch": STREAM_EPOCH,
            "rtp": {"clock_rate": 90000},
        }
    )
    proc.stdin.write(control_line + "\n")
    proc.stdin.flush()

    stderr_tail: deque[str] = deque(maxlen=80)
    up_event = threading.Event()
    line_count = [0]

    def drain_stderr() -> None:
        for line in proc.stderr:
            stderr_tail.append(line)
            if "cairn-detect up:" in line:
                up_event.set()

    def drain_stdout() -> None:
        with tmp_capture.open("w") as f:
            for line in proc.stdout:
                f.write(line)
                line_count[0] += 1

    t_err = threading.Thread(target=drain_stderr, daemon=True)
    t_out = threading.Thread(target=drain_stdout, daemon=True)
    t_err.start()
    t_out.start()

    # Poll the plugin process itself, not just the "up" event: if it dies
    # immediately (port already bound -- the only port-in-use handling this
    # has -- bad model path, missing shared lib), drain_stderr hits EOF and
    # its thread just exits with nobody setting or aborting up_event, so an
    # unpolled `up_event.wait(180)` would sit the full timeout before
    # reporting anything. Poll in a short loop instead so a dead plugin is
    # caught in well under a second, with its stderr tail attached.
    deadline = time.monotonic() + PLUGIN_STARTUP_TIMEOUT_S
    while not up_event.is_set():
        exit_code = proc.poll()
        if exit_code is not None:
            t_err.join(timeout=5)
            raise SystemExit(
                f"[{seq_name}] plugin exited during startup (code {exit_code}) before "
                f"printing 'cairn-detect up:'. stderr tail:\n{''.join(stderr_tail)}"
            )
        if time.monotonic() >= deadline:
            proc.kill()
            proc.wait()
            raise SystemExit(
                f"[{seq_name}] plugin never printed 'cairn-detect up:' within "
                f"{PLUGIN_STARTUP_TIMEOUT_S}s. stderr tail:\n{''.join(stderr_tail)}"
            )
        up_event.wait(timeout=0.5)
    print(f"[{seq_name}] plugin: up")

    # The cap must cover the real media, not the annotated span: a
    # PersonPath22 video runs past its 5 fps keyframe grid (seqLength there
    # counts annotation slots, not video frames), and a feed killed at the
    # shorter number reads as a failure. ffprobe the source; fall back to
    # the grid-derived duration for image-built videos, where they agree.
    duration = video_duration_s(video_path) or seqinfo["seq_length"] / seqinfo["frame_rate"]
    duration += 5.0
    feed_cmd = [
        "ffmpeg", "-nostdin", "-nostats", "-loglevel", "warning",
        "-re", "-stream_loop", "0",
        "-i", str(video_path),
        "-map", "0:v", "-c:v", "copy", "-bsf:v", "h264_mp4toannexb",
        "-f", "rtp", "-payload_type", "96", f"rtp://127.0.0.1:{port}",
    ]
    print(f"[{seq_name}] feed: {shlex.join(feed_cmd)} (cap {duration:.1f}s, one pass)")
    feed_proc = subprocess.Popen(
        feed_cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, start_new_session=True
    )
    # feed_proc runs in its own session (like verify/feed.py's precedent) so
    # that a signal delivered to this process doesn't also hit ffmpeg mid
    # real-time feed -- but unlike that precedent, there is no signal
    # handler pairing it back up. A finally-kill here covers the same
    # intent for e2e.py's shorter-lived, non-interactive run: Ctrl-C or any
    # exception during communicate() still lands here and makes sure ffmpeg
    # doesn't outlive us as an orphaned RTP sender racing the next run's
    # port.
    try:
        try:
            _, feed_err = feed_proc.communicate(timeout=duration)
            natural_exit = True
        except subprocess.TimeoutExpired:
            # Duration is a cap, not a target: a one-pass real-time feed
            # should finish on its own well inside it, so hitting this is
            # the feed hanging, not the normal case.
            feed_proc.terminate()
            try:
                _, feed_err = feed_proc.communicate(timeout=10)
            except subprocess.TimeoutExpired:
                feed_proc.kill()
                _, feed_err = feed_proc.communicate()
            natural_exit = False
    finally:
        if feed_proc.poll() is None:
            feed_proc.kill()
            feed_proc.wait()

    if not natural_exit:
        # A hung/killed feed means the capture covers only part of the
        # sequence -- it must never be renamed into the trusted, cached
        # path (the skip-if-exists check would trust it on every future
        # run). Kill the plugin and bail; tmp_capture is left as-is
        # (`.part`, ignored by the skip-if-exists check, truncated on retry).
        proc.kill()
        proc.wait()
        raise SystemExit(
            f"[{seq_name}] feed ffmpeg did not finish within the {duration:.1f}s cap "
            f"and was killed -- capture left unrenamed. stderr tail:\n{tail(feed_err)}"
        )
    if feed_proc.returncode != 0:
        proc.kill()
        proc.wait()
        raise SystemExit(f"[{seq_name}] feed ffmpeg exited {feed_proc.returncode}:\n{tail(feed_err)}")
    print(f"[{seq_name}] feed: done")

    feed_end = time.monotonic()
    time.sleep(2)
    proc.stdin.close()

    remaining = max(0.0, (feed_end + 30) - time.monotonic())
    try:
        proc.wait(timeout=remaining)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
        raise SystemExit(
            f"[{seq_name}] plugin outlived feed-end+30s, killed. stderr tail:\n{''.join(stderr_tail)}"
        )

    # The process is reaped, so its pipes are at EOF and the drain threads
    # exit on their own; the join must OUTLAST the flush, not race it — a
    # timed join returning early here would let the rename below consume a
    # capture still being written. The bound is a hang detector, not a
    # deadline the flush is allowed to lose.
    t_out.join(timeout=60)
    t_err.join(timeout=60)
    if t_out.is_alive() or t_err.is_alive():
        raise SystemExit(f"[{seq_name}] capture drain thread hung after plugin exit")

    # Closing stdin above is deliberate control-channel EOF, and the plugin
    # exits it with libc::_exit(3) by design (control.rs: "exiting so Cairn
    # respawns us") -- 3 is the expected code for exactly what we just did,
    # not a failure. Only something other than {0, 3} is one.
    if proc.returncode not in (0, 3):
        raise SystemExit(f"[{seq_name}] plugin exited {proc.returncode}. stderr tail:\n{''.join(stderr_tail)}")
    if line_count[0] == 0:
        raise SystemExit(f"[{seq_name}] plugin produced no output lines. stderr tail:\n{''.join(stderr_tail)}")

    tmp_capture.rename(capture_path)
    print(f"[{seq_name}] capture: {line_count[0]} lines -> {capture_path}")


def track_sequence(seq_dir: Path, capture_path: Path, pred_path: Path, policy_flags: list[str]) -> None:
    """Step 4: replay the capture through the real protocol + tracker."""
    seq_name = pred_path.stem
    if pred_path.exists():
        print(f"[{seq_name}] track: skipped (exists) {pred_path}")
        return

    pred_path.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        "mix", "cairn.mot.ndjson", str(capture_path),
        "--seq", str(seq_dir),
        "--out", str(pred_path),
        *policy_flags,
    ]
    print(f"[{seq_name}] track: {shlex.join(cmd)}")
    result = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(
            f"[{seq_name}] mix cairn.mot.ndjson failed:\n{tail(result.stdout)}\n{tail(result.stderr)}"
        )
    print(f"[{seq_name}] track: {result.stdout.strip().splitlines()[-1] if result.stdout.strip() else 'done'}")


def run_one_sequence(seq_dir: Path, args, policy_flags: list[str]) -> None:
    seqinfo = parse_seqinfo(seq_dir)
    seq_name = seqinfo["name"]

    # seq_name (seqinfo.ini's free-text `name`) and seq_dir.name both land
    # directly in path components below (captures/{seq_name}-{tag}.ndjson,
    # preds/e2e/<tag>/{seq_name}.txt, and the sibling-clip lookup in
    # build_video) -- validate before either is used as one. CVAT task
    # names are arbitrary and its export leaves seqinfo fields generic, so
    # this is reachable with real input, not just hostile input.
    if not valid_path_component(seq_name):
        raise SystemExit(
            f"seqinfo.ini `name` must match [A-Za-z0-9._-]+ and not contain '..' "
            f"(got {seq_name!r}) in {seq_dir / 'seqinfo.ini'}"
        )
    if not valid_path_component(seq_dir.name):
        raise SystemExit(
            f"sequence directory basename must match [A-Za-z0-9._-]+ and not contain "
            f"'..' (got {seq_dir.name!r}): {seq_dir}"
        )
    # score.py matches predictions to ground truth by directory name
    # (pred stem == gt dir name), so a seqinfo `name` that disagrees with
    # its own directory's basename silently scores as "Missing ground
    # truth" downstream -- catch it here with a clear message instead.
    if seq_name != seq_dir.name:
        raise SystemExit(
            f"seqinfo.ini `name` ({seq_name!r}) must equal the sequence directory's "
            f"basename ({seq_dir.name!r}) -- score.py matches preds to gt by this name: {seq_dir}"
        )

    videos_dir = ROOT / "data" / "e2e" / "videos"
    captures_dir = ROOT / "data" / "e2e" / "captures"
    captures_dir.mkdir(parents=True, exist_ok=True)

    capture_path = captures_dir / f"{seq_name}-{args.tag}.ndjson"
    pred_path = ROOT / "data" / "preds" / "e2e" / args.tag / f"{seq_name}.txt"

    if capture_path.exists():
        print(f"[{seq_name}] capture: skipped (exists) {capture_path}")
    else:
        video_path = build_video(seq_dir, seqinfo, videos_dir)
        run_plugin_and_feed(args, seq_name, seqinfo, video_path, capture_path)

    track_sequence(seq_dir, capture_path, pred_path, policy_flags)


def policy_flags(args) -> list[str]:
    """Only pass through what the user actually gave -- an unset flag here
    should fall back to `mix cairn.mot.ndjson`'s own default, not silently
    pin one."""
    flags: list[str] = []
    if args.bbd is not None:
        flags.append("--bbd" if args.bbd else "--no-bbd")
    if args.oru is not None:
        flags.append("--oru" if args.oru else "--no-oru")
    if args.ocr is not None:
        flags.append("--ocr" if args.ocr else "--no-ocr")
    if args.reid is not None:
        flags.append("--reid" if args.reid else "--no-reid")
    if args.min_score is not None:
        flags += ["--min-score", str(args.min_score)]
    return flags


def score_all(args) -> None:
    """Step 5: score every sequence run under this tag in one shot -- the
    same interface matrix.py's score_cell drives score.py with."""
    preds_dir = ROOT / "data" / "preds" / "e2e" / args.tag
    out_dir = ROOT / "data" / "results" / "e2e" / args.tag
    out_dir.mkdir(parents=True, exist_ok=True)

    cmd = [
        str(ROOT / ".venv" / "bin" / "python"), str(ROOT / "score.py"),
        "--preds", str(preds_dir),
        "--tracker-name", args.tag,
        "--gt-root", str(args.gt_root),
        "--benchmark", args.benchmark,
        "--split", args.split,
        "--out", str(out_dir),
    ]
    print(f"score: {shlex.join(cmd)}")
    result = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(f"score.py failed:\n{tail(result.stdout)}\n{tail(result.stderr)}")
    print(result.stdout)
    print(f"score: done -> {out_dir}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--seqs", nargs="+", type=Path, required=True, help="gt sequence directories")
    parser.add_argument("--tag", required=True, help="config label, [A-Za-z0-9._-]+")
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--labels", type=Path, required=True)
    parser.add_argument("--embedder-model", type=Path, default=None)
    parser.add_argument("--sample-fps", type=int, default=30)
    parser.add_argument("--udp-port", type=int, default=17400)
    parser.add_argument("--plugin-bin", type=Path, default=DEFAULT_PLUGIN_BIN)

    parser.add_argument("--bbd", action=argparse.BooleanOptionalAction, default=None)
    parser.add_argument("--oru", action=argparse.BooleanOptionalAction, default=None)
    parser.add_argument("--ocr", action=argparse.BooleanOptionalAction, default=None)
    parser.add_argument("--reid", action=argparse.BooleanOptionalAction, default=None)
    parser.add_argument("--min-score", type=float, default=None)

    parser.add_argument("--gt-root", type=Path, default=ROOT / "data" / "trackeval_gt" / "data" / "gt" / "mot_challenge")
    parser.add_argument("--benchmark", default=None, help="e.g. MOT17 (required unless --no-score)")
    parser.add_argument("--split", default="train")
    parser.add_argument("--no-score", action="store_true")

    args = parser.parse_args()

    if not valid_path_component(args.tag):
        raise SystemExit(f"--tag must match [A-Za-z0-9._-]+ and not contain '..' (got {args.tag!r})")
    if not args.no_score and not args.benchmark:
        raise SystemExit("--benchmark is required unless --no-score is given")

    args.model = args.model.resolve()
    args.labels = args.labels.resolve()
    if not args.model.is_file():
        raise SystemExit(f"--model not found: {args.model}")
    if not args.labels.is_file():
        raise SystemExit(f"--labels not found: {args.labels}")
    if args.embedder_model is not None:
        args.embedder_model = args.embedder_model.resolve()
        if not args.embedder_model.is_file():
            raise SystemExit(f"--embedder-model not found: {args.embedder_model}")

    args.plugin_bin = args.plugin_bin.resolve()
    if not args.plugin_bin.is_file():
        raise SystemExit(f"--plugin-bin not found: {args.plugin_bin}")

    args.gt_root = args.gt_root.resolve()

    seqs = [s.resolve() for s in args.seqs]
    for seq_dir in seqs:
        if not seq_dir.is_dir():
            raise SystemExit(f"--seqs entry is not a directory: {seq_dir}")

    flags = policy_flags(args)

    for seq_dir in seqs:
        run_one_sequence(seq_dir, args, flags)

    if not args.no_score:
        score_all(args)
    else:
        print("score: skipped (--no-score)")


if __name__ == "__main__":
    main()
