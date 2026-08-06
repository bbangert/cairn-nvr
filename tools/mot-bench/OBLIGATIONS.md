# Dataset & tooling obligations

This harness downloads third-party datasets on demand (`data/` is
gitignored, never committed) and vendors a pinned TrackEval checkout
(`vendor/`, also gitignored). Each has its own license and use
restrictions, summarized here and applying at publication time even though
local evaluation is unrestricted.

| Dataset / tool | License | Redistribution | Commercial use | Citation if results published |
| --- | --- | --- | --- | --- |
| MOT17 | CC BY-NC-SA 3.0 | Not permitted in this repo | Not permitted | arXiv:2010.07548 |
| MOT20 | CC BY-NC-SA 3.0 | Not permitted in this repo | Not permitted | arXiv:2010.07548 |
| PersonPath22 | CC BY-NC 4.0 + responsible-use terms | Not permitted in this repo | Not permitted | arXiv:2211.02175 |
| TrackEval | MIT | Vendored via pinned git clone, not committed | Permitted | — |

## MOT17 / MOT20

Licensed CC BY-NC-SA 3.0 (non-commercial, share-alike). Local evaluation
against these labels for internal accuracy measurement is unrestricted. If
results derived from MOT17/MOT20 are published, cite the MOTChallenge paper
(arXiv:2010.07548). Clips and labels must never be redistributed as part of
this repository — that's why `data/` is gitignored and `fetch.py` downloads
them on demand instead. The non-commercial restriction applies to any
downstream use of the data itself (not to the cairn-nvr software).

## PersonPath22

Licensed CC BY-NC 4.0 plus dataset-specific responsible-use terms. Local
evaluation is fine. If results are published, cite arXiv:2211.02175. No
redistribution of the annotations or derived clips. The dataset's terms
explicitly prohibit use for biometric identification or re-identification of
individuals. This harness only uses PersonPath22 for anonymous, short-term
track-association accuracy measurement (does this predicted box graph match
the ground-truth box graph, frame to frame) — it does not identify, verify,
or re-identify any person, and no per-person identity information is stored
or produced anywhere in this pipeline.

## TrackEval

MIT licensed. Used via a pinned git clone into `vendor/trackeval/`
(gitignored, not committed) rather than vendored as source in this repo.

## Wayback Machine fallback URLs

`fetch.py` falls back to `web.archive.org` copies of the MOT17/MOT20 zips
when `motchallenge.net` is unreachable. These are archival copies of the
identical official files — the same MOT17/MOT20 licenses and obligations
above apply to them.

## House rule

Restrictive (non-commercial, no-redistribution) datasets stay usable for
local evaluation and development. The obligation isn't "don't use it" — it's
"track it here, and honor it at the point where results leave this repo":
citing the right paper, not committing the raw data, and not using
PersonPath22 for anything resembling identification.
