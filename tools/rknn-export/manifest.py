#!/usr/bin/env python3
"""Hash a rung directory. usage: manifest.py DIR [BUILD_DIR]
Writes DIR/MANIFEST.sha256 (sha256sum format, bare names: `sha256sum -c` works
from inside DIR, busybox included) and DIR/MANIFEST.json. Build facts come from
BUILD_DIR/NAME.json (default DIR/../final/build); a rung's twin is the .onnx in
DIR whose hash is the one the rung was converted from. Exits non-zero, writing
nothing, unless every .rknn has a build JSON with all steps ok and an
rknn_sha256 equal to the file's hash."""
import hashlib, json, os, sys

d = os.path.abspath(sys.argv[1])
build = os.path.abspath(sys.argv[2] if len(sys.argv) > 2 else os.path.join(d, "..", "final", "build"))
sha = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
files = sorted(f for f in os.listdir(d) if not f.startswith("MANIFEST"))
assert files and all(f.endswith((".rknn", ".onnx")) for f in files), files
hashes = {f: sha(os.path.join(d, f)) for f in files}
twins = {h: f for f, h in hashes.items() if f.endswith(".onnx")}
rows, bad = [], []
for f in files:
    row = {"file": f, "sha256": hashes[f], "bytes": os.path.getsize(os.path.join(d, f)),
           "role": "rknn" if f.endswith(".rknn") else "twin",
           "license": "Apache-2.0" if f.startswith("yolox") else "AGPL-3.0"}
    if row["role"] == "rknn":
        jp = os.path.join(build, f[:-5] + ".json")
        if not os.path.exists(jp): bad.append(f"{f}: no build json {jp}"); continue
        b = json.load(open(jp))
        # the json is keyed by name only; the hash is what says it describes these bytes
        if any(v != "ok" for v in b["steps"].values()): bad.append(f"{f}: build steps not ok {b['steps']}"); continue
        if b.get("rknn_sha256") != hashes[f]: bad.append(f"{f}: build json rknn_sha256 {b.get('rknn_sha256')} != file {hashes[f]}"); continue
        row.update(twin=twins[b["source_sha256"]], toolkit=b["toolkit"], target=b["target_platform"], mode=b["mode"],
                   quantized_algorithm=b["quantized_algorithm"], calib_set_id=b["calib_set_id"],
                   calib_policy=b["calib_policy"], source_sha256=b["source_sha256"])
    rows.append(row)
if bad: sys.exit("manifest not written:\n" + "\n".join(bad))
open(os.path.join(d, "MANIFEST.sha256"), "w").write("".join(f"{h}  {f}\n" for f, h in hashes.items()))
json.dump(rows, open(os.path.join(d, "MANIFEST.json"), "w"), indent=1)
print(len(rows), "files ->", d)
