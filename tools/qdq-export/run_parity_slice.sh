#!/bin/bash
# P3-T1 of the erpc-driver-port plan: the same cheap campaign slice
# (nano rung, one clip) through BOTH drivers, back to back in one
# sitting, then a transport-invisibility diff of the evidence trees.
# Self-logging: everything lands under $PARITY; the exit code is the
# comparator's verdict. ~30 min per side (envcheck + 3 content runs +
# 2 bench runs + reboots).
#
#   tools/qdq-export/run_parity_slice.sh [parity-dir]
#
# The erpc side runs second on purpose: its finish ends in a verified
# reboot, so the board is left with distribution OFF either way.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$HERE/out-20260820
PARITY=${1:-$HERE/parity-$(date +%Y%m%d-%H%M%S)}
SLICE_RUNGS="yolox_nano-qdq-a16:yolox:416"
SLICE_CLIPS="ac86"

log() { echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$PARITY/parity.log"; }

mkdir -p "$PARITY"
for side in bash erpc; do
  mkdir -p "$PARITY/$side"
  # The campaign reads artifacts/records/clips relative to OUT; symlink
  # the real ones so both sides push byte-identical inputs.
  for d in artifacts records clips; do
    [ -e "$PARITY/$side/$d" ] || ln -s "$SRC/$d" "$PARITY/$side/$d"
  done
done

log "== parity slice: RUNGS=$SLICE_RUNGS CLIPS=$SLICE_CLIPS"
log "== bash driver"
RUNGS="$SLICE_RUNGS" CLIPS="$SLICE_CLIPS" OUT="$PARITY/bash" \
  "$HERE/run_htp_campaign.sh" all > "$PARITY/bash-driver.log" 2>&1
BASH_RC=$?
log "bash driver rc=$BASH_RC"

log "== erpc driver"
(cd "$HERE/driver" &&
  RUNGS="$SLICE_RUNGS" CLIPS="$SLICE_CLIPS" OUT="$PARITY/erpc" \
    mix run -e 'Driver.CLI.main(System.argv())' -- all) > "$PARITY/erpc-driver.log" 2>&1
ERPC_RC=$?
log "erpc driver rc=$ERPC_RC"

log "== comparing evidence trees"
python3 - "$PARITY/bash/htp" "$PARITY/erpc/htp" > "$PARITY/parity-report.txt" 2>&1 <<'EOF'
import os, sys

bash_htp, erpc_htp = sys.argv[1], sys.argv[2]
failures = []


def check(name, ok, detail=""):
    print(f"{'PASS' if ok else 'DIFF'}  {name}" + (f"  {detail}" if detail else ""))
    if not ok:
        failures.append(name)


def content_tags(root):
    d = os.path.join(root, "content")
    return sorted(x for x in os.listdir(d) if os.path.isdir(os.path.join(d, x))) if os.path.isdir(d) else []


b_tags, e_tags = content_tags(bash_htp), content_tags(erpc_htp)
check("content: same run tags", b_tags == e_tags, f"bash={b_tags} erpc={e_tags}")

# "up after ~Ns" is boot-timing and frame counts wobble ±1 run-to-run
# (live-feed sampling boundary — measured on bash-vs-erpc AND across
# bash's own campaigns); everything else in the marker file — governor,
# backend/profile/insize, model+clip shas, feed exit — must be
# byte-identical. Counts get a small tolerance instead of exactness.
VOLATILE = ("up after ", "frame.objects lines:")
FRAME_TOLERANCE = 3
for tag in [t for t in b_tags if t in e_tags]:
    b_dir, e_dir = (os.path.join(r, "content", tag) for r in (bash_htp, erpc_htp))
    b_files, e_files = (sorted(os.listdir(d)) for d in (b_dir, e_dir))
    check(f"{tag}: file set", b_files == e_files, f"bash={b_files} erpc={e_files}")

    def meta_lines(d):
        with open(os.path.join(d, "meta")) as f:
            return [l.rstrip("\n") for l in f]

    if "meta" in b_files and "meta" in e_files:
        bl, el = meta_lines(b_dir), meta_lines(e_dir)
        stable = [[l for l in ls if not any(l.startswith(v) for v in VOLATILE)] for ls in (bl, el)]
        check(f"{tag}: meta stable lines", stable[0] == stable[1],
              "" if stable[0] == stable[1] else f"\n  bash: {stable[0]}\n  erpc: {stable[1]}")

        counts = [next((int(l.split(":")[1]) for l in ls if l.startswith("frame.objects lines:")), None)
                  for ls in (bl, el)]
        ok = None not in counts and abs(counts[0] - counts[1]) <= FRAME_TOLERANCE
        check(f"{tag}: meta frame.objects within ±{FRAME_TOLERANCE}", ok,
              f"bash={counts[0]} erpc={counts[1]}")

    if "out.ndjson" in b_files and "out.ndjson" in e_files:
        counts = []
        for d in (b_dir, e_dir):
            with open(os.path.join(d, "out.ndjson")) as f:
                lines = f.readlines()
            counts.append((len(lines), sum(1 for l in lines if '"frame.objects"' in l or "'frame.objects'" in l)))
        ok = all(abs(a - b) <= FRAME_TOLERANCE for a, b in zip(counts[0], counts[1]))
        check(f"{tag}: ndjson counts within ±{FRAME_TOLERANCE} (total, frame.objects)", ok,
              f"bash={counts[0]} erpc={counts[1]}")

for name in ("spike-env.txt", "campaign.log"):
    check(f"presence: {name}",
          all(os.path.isfile(os.path.join(r, name)) for r in (bash_htp, erpc_htp)))


def run_shapes(root):
    d = os.path.join(root, "runs")
    if not os.path.isdir(d):
        return []
    return sorted(sorted(os.listdir(os.path.join(d, r))) for r in os.listdir(d))


b_runs, e_runs = run_shapes(bash_htp), run_shapes(erpc_htp)
check("bench runs: count + per-run file sets", b_runs == e_runs,
      f"bash={b_runs} erpc={e_runs}")

print()
if failures:
    print(f"VERDICT: DIFF in {len(failures)} check(s): {failures}")
    sys.exit(1)
print("VERDICT: PARITY — transport is invisible in the evidence")
EOF
CMP_RC=$?

tail -1 "$PARITY/parity-report.txt" | tee -a "$PARITY/parity.log"
log "done: bash rc=$BASH_RC erpc rc=$ERPC_RC compare rc=$CMP_RC (report: $PARITY/parity-report.txt)"
[ "$BASH_RC" = 0 ] && [ "$ERPC_RC" = 0 ] && [ "$CMP_RC" = 0 ]
