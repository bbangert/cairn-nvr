# Vendored reference trackers — provenance and patches

`setup.sh` vendors three appearance-free MOT tracker cores into the
gitignored `vendor/` directory (same pattern as TrackEval) for
`bytetrack_sweep.py`:

| tracker | upstream | pinned SHA | license | patch |
|---|---|---|---|---|
| bytetrack | https://github.com/ifzhang/ByteTrack | d1bf0191adff59bc8fcfeaa0b33d3d1642552a99 | MIT | bytetrack.patch |
| ocsort | https://github.com/noahcao/OC_SORT | 8462e7e729a93ccd3bd995c0a79a890336cb3a0b | MIT | none (verbatim) |
| sparsetrack | https://github.com/hustvl/SparseTrack | 499844f32c5bb2332f9811f26cd70cf4e517d4e7 | MIT | sparsetrack.patch |

The patches are mechanical, never algorithmic:

- **bytetrack.patch** — unused `torch`/`cv2`/`time` imports stripped;
  `yolox.tracker` imports made relative; `cython_bbox.bbox_overlaps`
  replaced with a numpy IoU of the same semantics (the +1 pixel
  convention), because cython_bbox does not build against the pinned
  numpy 1.23.5.
- **sparsetrack.patch** — unused `torch` imports stripped; the compiled
  `pbcvt` GMC module import made optional and its call guarded (GMC only
  runs when a caller passes images, which the detections-only harness
  never does; the authors' own MOT20 protocol runs GMC disabled); the
  detectron2 `Instances` unpack in `update()` replaced with a plain
  numpy `(N, 5)` interface; `cython_bbox` IoU reuses bytetrack's numpy
  replacement; `tracker.*` imports made relative.

Regenerating a patch after editing a vendored file: diff the pristine
upstream file (clone at the pinned SHA) against `vendor/<name>/<file>`
with `-L a/<file> -L b/<file>` labels and overwrite the entry here.
