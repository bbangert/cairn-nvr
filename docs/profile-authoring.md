# Writing a hardware profile

A **profile** is one YAML file that names, in one place, everything about how
a piece of hardware runs detection: which model artifact, which family, which
inference runtime, what frame rate to expect, and which tracker stages to run
behind it. A plugin group names its profile; config load expands that one file
into *both* halves of the boundary — the in-VM engine's model config and the
host's tracker stage list — so the two cannot disagree with each other.

A profile is **data composing curated code**. Every field names something that
already exists: a family the Rust catalog ships, a backend the plugin can
name, a stage the tracker implements. There are no free knobs here — a value
this file does not accept is one nothing in cairn implements.

You do not need a profile. Nothing in the config requires one and no default
config has one; a camera without a profiled group behaves exactly as it always
has. You want one when you are running cairn on an accelerator, when you want
the model choice to be a reviewable file rather than a line of argv, or when
different cameras on one node run different hardware.

Shipped profiles live in `priv/profiles/`; yours live wherever you point
`profile_dirs:`. The schema and every validation message quoted below come
from `Cairn.Config.Profile`.

## Attaching one

Three config keys, none of which existed before profiles:

```yaml
# Where your own profiles live. Cairn's shipped dir is always searched first;
# these are searched after, so a file of yours shadows a shipped one of the
# same name — with a warning naming the file that won.
profile_dirs:
  - /etc/cairn/profiles

plugins:
  detect:
    # The profile's filename, without .yml. A group is nothing but this
    # reference and your consent flags — the external-plugin `command:` form
    # died with membrane port phase 6.
    profile: rk3566-lowfps
    # Required to run a profile whose backend is not `ort`: only `ort`
    # executes today, and the other two names exist so a board profile can be
    # written and validated before its runtime lands. Both halves are needed —
    # the profile says `experimental: true`, you say `allow_experimental: true`
    # — because one is the author's claim and the other is your consent.
    allow_experimental: true

cameras:
  - id: driveway
    rtsp_url: rtsp://…
    # The group's profile reaches this camera's tracker. Cameras never name a
    # profile themselves.
    plugin: detect
```

## The schema

Every key, annotated. All are optional except that a profile which some group
actually runs must name an artifact for its own backend.

```yaml
# <profile_dirs entry>/my-board.yml
name: my-board             # optional; when present it must equal the filename
tier: 2                    # optional; the capability rung this profile claims
experimental: true         # this profile is unproven — see below
backend: rknn              # which runtime executes the model
model:                     # one artifact path per backend, not one model
  onnx: models/yolox_nano.onnx
  rknn: models/yolox_nano_rk3566.rknn
model_profile: yolox       # the detector family, from the plugin's catalog
input_size: 416            # square N; the model's own geometry when omitted
decoder: auto              # the *video* decode path — not the backend
labels: models/coco.names  # class names, indexed positionally
fps_band: [2, 4]           # declared, not measured
sample_fps: 3              # optional; fps_band only validates it, never emits it

tracking:                  # the stage list, plus band-tuned tracker bounds
  bbd: true
  oru: true
  ocr: true
  twin_mint: true
  max_unseen_ms: 3000
  max_live_tracks: 128
  stationary_after_ms: 10000
```

Paths are taken **verbatim** and resolved by the OS against the working
directory cairn itself was started from — the same one the plugin is spawned
into. Nothing here rewrites a path, because a rewrite would check one file and
hand the plugin another.

`model:` is keyed per backend rather than being a single path because backends
consume different files. An `.rknn` is compiled from an `.onnx` by a host-side
toolchain; a QNN profile loads a QDQ-quantized graph which is still an `.onnx`
by format but is not the same file as the fp32 export. One profile can
therefore carry the artifacts for several backends, and its own `backend:`
picks which one becomes `--model`.

## `tier:` — the ascending capability ladder

`tier:` names the capability a profile claims, on a ladder that ascends:

* **1 — presence detection.** Per-class present/cleared events. No object
  identity, no tracks, no track persistence: a tier-1 pipeline runs no
  tracker at all, which is why a tier-1 profile with a `tracking:` block is
  a config error — the block describes machinery the tier turns off.
  `record:` keeps its meaning here — its labels gate which presence
  detections earn a recording, and a recording is an ordinary event: a row,
  a clip, a snapshot with the trigger box drawn on it. `max_event_seconds`
  segments such a recording rather than ending it, so a presence that
  outlives the cap yields consecutive clips for as long as it lasts.
  `track:` has nothing to gate without a tracker; config warns per camera
  when it is set on a tier-1 profile.
* **2 — accurate MOT.** Tracked objects with identity and persistence.
  The measured accuracy bar and per-board capacity will live in each
  board's tier file when those ship.
* **Higher rungs are reserved** for capabilities that do not exist yet
  (ALPR, facial identification, …). Validation names the rungs that ship
  today — `1` and `2` — and widens as new ones do; the schema shape never
  changes.

Omitting `tier:` means the profile makes no capability claim and nothing
changes: every tier-less profile behaves exactly as it did before the key
existed. **Declaring `tier: 1` changes the runtime**: the group's cameras
build the presence pipeline — detections feed per-class present/cleared
events (`presence_started`/`presence_cleared` on the event stream) and no
tracker of any kind runs, which is why changing a profile's tier restarts
its cameras rather than refreshing them. `tier: 2` selects today's
tracked pipeline and refuses cameras carrying `motion_json:` (the gate
starves the tracker of the frames it skips — see the D-P6 section below).

The word "tier" also appears on cameras (`track:`/`record:` score
thresholds); that is a different, older axis. This ladder is per-profile
and therefore per-group.

## `model_ladder:` — one file, a range of models

A tier file can describe a MODEL LADDER instead of one model: an ordered
rung list, most accurate first, each rung a complete model choice with a
measured engine budget. At every config load, cairn counts the cameras
with detection configured on the node (N — the count of configured
cameras, never the runtime detection toggle) and resolves the first rung
whose budget covers N at the tier's floor rate. A small fleet gets the
most accurate model the board can afford; a growing one walks down the
ladder; nobody configures a model, ever. `qcs6490-tier1.yml` is the
shipped worked example.

```yaml
tier: 1                        # required — the floor rate is the tier's
model_ladder:
  - model:
      qnn: data/models/yolo26m-qdq-a16.onnx
    model_profile: yolo26      # per-rung; omitted, the top-level one stands
    input_size: 640            # per-rung — 640 and 416 rungs are the norm
    engine_budget: 18.5        # passes/s — provisional bench arithmetic
                               # until the rung's boundary ladder run
    pack: yolo26m              # skipped (with a warning) until installed
  - model:
      qnn: models/yolox_nano-qdq-a16.onnx
    input_size: 416
    engine_budget: 75
supported_cameras: 40          # the support claim, enforced as a bound
```

The rules, each refused or warned at load:

* **The ladder is the model and rate authority (D-L4).** `model_ladder:`
  is mutually exclusive with `model:`, `input_size:`, `sample_fps:` and
  `fps_band:` — the resolved rung is the model, and each camera's
  `sample_fps` is derived from the rung's budget: the largest nominal
  rate between the tier floor and 10 whose *effective* demand fits.
  Effective, because the sample gate quantizes to the frame grid — "2
  fps" delivers 1.875/s on the 15 fps substreams the capacity numbers
  were measured on. A fleet on substreams at a different rate shifts the
  effective rates; the budgets assume 15.
* **`supported_cameras:` is a claim and a bound.** It is the camera count
  the file stands behind (measured, soak-checked provenance in the file's
  comments), and a fleet past it is refused at load even when a rung's
  budget would cover it — capacity arithmetic does not extend a claim
  nobody verified.
* **The Apache-complete invariant (D-L2).** Rungs marked `pack:` name
  models installed separately (AGPL packs under the data dir); while the
  artifact is absent the rung is skipped with a warning naming the pack
  and, when it would have won, what installing it buys. The non-pack
  rungs alone must cover `supported_cameras` — packs raise accuracy at a
  fleet size, they never extend support, and a ladder that leans on them
  for any camera count is refused at parse.
* **Ordering is reachability, not blanket monotonicity.** The list is the
  author's accuracy claim, most accurate first, and resolution takes the
  first installed rung that fits — so a rung is refused exactly when a
  rung above it that can never be absent while this one is available
  budgets at least as much: no installation state could ever reach it.
  That shadow is every non-`pack:` rung (always present) plus any `pack:`
  rung naming the same active-backend artifact path (same path = installed
  and absent together). A rung under a bigger-budget *independent* `pack:`
  rung is legitimate by design — it wins exactly when that pack is absent,
  which is how one ladder serves both installation states (the shipped
  file's yolox_m under yolo26s: dominated when the pack is installed,
  the small-fleet rung when only the baked Apache models exist).
* **Budgets are measurements (D-L6).** Every `engine_budget` carries a
  provenance comment — `measured` (a boundary capacity-ladder run) or
  `provisional` (menu arithmetic) — and a file whose NON-pack rungs
  carry any provisional budget says DRAFT at the top. Pack rungs are
  exempt from the DRAFT escalation, never from the note: their
  artifacts do not exist until the pack ships, so their boundary runs
  cannot either, and the Apache-complete invariant keeps them off the
  claim path — each owes its run when the pack lands. The gate in the
  test suite reads the raw file and refuses a shipped ladder without
  the notes.

Two consequences worth an operator's attention:

* **A fleet edit can change the model.** Adding or removing detecting
  cameras moves N; crossing a rung boundary is a model change, and the
  detecting cameras restart through the ordinary reload path (engine
  first, then the cameras). Presence state rides out the restart the way
  it does any camera restart — but expect the discontinuity when you grow
  the fleet across a boundary.
* **Score thresholds apply across every rung (D-L3).** Score
  distributions shift between models — one rung's export hugs the 0.5
  floor where another spans 0.51–0.81 — so `min_score`/`track:`/`record:`
  values tuned on one rung behave differently on another, and the rung
  follows fleet size. Config warns per camera when a multi-rung ladder
  serves customized thresholds; verify them against each rung your fleet
  can resolve. Per-rung threshold overlays are deliberately absent until
  a measured calibration story exists.

## The menus, and where each lives in code

| field | menu | where the menu lives |
|---|---|---|
| `backend` | `ort`, `rknn`, `qnn` | `BackendKind`, `plugins/cairn-detect/src/infer/backend.rs` — mirrored in `Cairn.Config.Profile`'s capability table |
| `model_profile` | `yolox`, `yolov10`, `yolov8` (or `yolov9`, `yolo11`, `yolov11`, `yolo26`), `rfdetr` (hyphenated spelling accepted) | `PROFILES`, `plugins/cairn-detect/src/infer/catalog.rs` |
| `decoder` | `auto`, `vaapi`, `qsv`, `nvdec`, `v4l2`, `videotoolbox`, `sw` | `DecoderKind`, `plugins/cairn-detect/src/decode.rs` |
| `tracking:` stage keys | `bbd`, `oru`, `ocr`, `twin_mint` | `Cairn.Tracker.Stage.Bbd` / `.Oru` / `.Ocr` / `.TwinMint` |

Each catalog row is a decode contract listing the model families it applies
to: `yolo11` and `yolov8` share one row because several Ultralytics
generations export byte-identical tensor layouts, and the error messages say
which decode contract a family resolves to.

`decoder:` and `backend:` are different knobs that both sound like "how do I
run this fast". `decoder:` is the **video** path — how H.264 frames get
decoded. `backend:` is the **inference** path — what executes the model.
Naming a hardware video decoder says nothing about where the model runs.

Naming one is a **requirement**: if the device or the hwaccel is missing, the
decoder refuses the software fallback and the camera's detect branch goes dark
with the reason on `cameras:status`, while recording carries on. (The refusal
lands when the hardware probe decides, which for a live H.264 stream is at the
first keyframe: the probe waits for the stream's own SPS/PPS before opening —
see `decode::open` in `plugins/cairn-detect/src/decode.rs`.) Write `decoder: auto` — the default — to mean "the best available, software
if that is all there is". The distinction is worth the refusal on a board: on
QCS6490 the ASIC decodes the whole fleet for about 2% CPU where software decode
costs several times that per camera — decode is the term this knob controls;
the scale/convert after it is paid on both paths — and before this a profile
naming `v4l2` on a box without it just quietly ran the software decoder. The external plugin still falls back instead of
refusing, because there its refusal would be a process exit into a restart loop;
that half goes away with the plugin path itself.

`labels:` is indexed positionally, so the file has to match the family's class
space: 80 lines for yolox and the Ultralytics families, 91 for rfdetr, which
indexes logits by raw COCO category id (`coco91.names`). The plugin refuses to
start on a count mismatch rather than emit every detection under a neighbour's
name.

`fps_band` is **declared, not measured** (D-P5). It is the rate this hardware
is expected to sustain, written down so stage sets and defaults can be chosen
against it; nothing observes the real rate and adapts. Every band cairn ships
carries a comment saying what it was derived from and that it is pending
on-hardware measurement — write yours the same way, and treat a band as data
that is cheap to correct.

A band is only ever replaced by measurement **on a deployment target**, which
means an SBC. The x86 box in this repo's development loop is a test host: it
runs the gates, the parity harness and the accuracy work, and it never gets a
measured band, because nothing ships there and a number from it would describe
hardware no deployment has. That is why `generic-ort.yml` — a migration alias
rather than a hardware class — keeps a declared `[5, 5]` and is expected to keep
it. Measured bands come from the RK3576 and RK3566 profiles, each on its own
board, with the cpufreq governor pinned and recorded (see
`docs/npu-backends.md` on why an unpinned governor makes a plausible-looking
wrong number). The QCS6490 has no band to measure any more: its ladder file
derives the rate per rung, and what it owes measurement instead is each
rung's `engine_budget` (D-L6).

`sample_fps` is optional, and **the band validates it, the band never emits
it** (D-P4): leave `sample_fps:` unset and no `--sample-fps` flag is written
regardless of what `fps_band:` says, and the plugin keeps its own default of
5. Set it and it becomes `--sample-fps <value>`, checked at load against the
same `1..30` bound the plugin's own flag parsing enforces. If the profile also
declares an `fps_band:`, `sample_fps:` must fall inside it — a value outside
the band is a config error naming both, since a profile that both bounds a
rate and then names a value outside that bound is contradicting itself, not
expressing a choice. A profile with `fps_band:` and no `sample_fps:` is
unaffected either way: none of the four board profiles cairn ships sets
`sample_fps:`, and their bands keep emitting nothing.

The one profile shape this paragraph does not describe is a `model_ladder:`
profile, which may declare neither key (both are refused alongside a
ladder): there, config load itself derives `sample_fps` from the resolved
rung's measured budget and the fleet size, and the derived value — never a
crate default — is what reaches the engine. See "`model_ladder:` — one
file, a range of models" above.

## The `tracking:` block

The block is the stage list, and it expresses **presence, not order**: a stage
key present means that stage runs, absent means it does not, and the tracker's
own fixed insertion points decide where. There is deliberately no way to order
them — the algorithms have no legal reordering freedom, and a config that
looked like it could choose one would be lying.

Three states, and the difference between the last two matters:

- **key present** (`bbd: true`, or a params mapping) — the stage runs.
- **key absent, block present** — the stage does not run; `bbd: false` says the
  same thing more loudly, and is worth writing where the omission would look
  like an oversight. A `tracking:` block
  with no stage keys at all means "run nothing", which is a real choice — the
  way an NMS-free profile would turn off the cold-start twin gate every
  shipped profile leaves on (the retired `qcs6490.yml` placeholder did
  exactly this; its tier-1 successor runs no tracker at all).
- **block absent entirely** — the profile says nothing about tracking, and the
  camera's global `tracking.bbd`/`tracking.oru`/`tracking.ocr` booleans stand
  as they always did. A backend-only profile does not silently delist
  anything.

`tracking.reid` (Re-ID appearance fusion) is not part of this block and has no
profile form yet — a profile can neither list nor delist it. It keeps applying
to a profiled camera the same as an unprofiled one, for whatever the group's
own stage list leaves its one seam, the bbd admission, able to do: a profiled
group whose stage list carries no `bbd` silences it just as surely as the
global `tracking.bbd: false` would, and gets its own load warning saying so
(below), separate from the bbd/oru/ocr one.

`true` and an empty mapping mean the same thing. A params mapping is carried
through to the stage, and **no stage cairn ships reads its params today** —
every one of the four takes its constants from its own module. Write
`bbd: true`; a `bbd: {threshold: 0.4}` will parse, reach the stage, and change
nothing.

The three bounds beside the stage keys — `max_unseen_ms`, `max_live_tracks`,
`stationary_after_ms` — *are* read, and so is `tracker`, which names the
tracker core the group's cameras run. They resolve camera → profile → global:
a camera's own override outranks its group's profile, and the profile's
band-tuned value outranks the global default. The bounds are validated against
the same ranges the global keys are; an unknown `tracker` name is a config
error.

Two knobs stay outside profiles on purpose (D-P6): the motion-zone and
track-floor scene config describe the *scene* rather than the model, so they
are per-stream operator config — a camera's `motion_json:` key — never a
profile's. The one thing a profile says about them is a refusal: a tier-2
group rejects a camera carrying `motion_json:` at load (D-S4), because a
motion gate starves the tracker of exactly the frames it skips and tier 2's
claim is accuracy. Tier-1 and tier-less cameras gate freely; config never
writes a motion flag on anyone's behalf. This matters for `bbd`,
whose measured win is a composition with the track floor — with the floor off
it bought nothing at all, because an expired track has no row left to admit
against.

## The capability table, and what it refuses

`Cairn.Config.Profile` carries a static table of what each backend accepts,
mirroring `BackendKind::capabilities` on the Rust side. It is static because
config load has to answer these questions with no plugin running and, for a
board profile written ahead of its hardware, no such device attached.

| backend | artifact key | runs a fused-NMS export | takes dynamic shapes |
|---|---|---|---|
| `ort` | `model.onnx` | yes | yes |
| `rknn` | `model.rknn` | no | no |
| `qnn` | `model.qnn` | no | no |

Two rules come out of it, both from `docs/npu-backends.md`:

1. **A backend that cannot run the NMS op needs a family that does not need
   one.** Either an NMS-free head (`yolov10`'s end-to-end head, `rfdetr`'s
   queries) or a family cairn suppresses host-side on the CPU (`yolox`,
   `yolov8`). Every family in today's catalog satisfies this, so the rule
   cannot fire from the menu as it stands — it is in the code as data so that
   a family added later with suppression fused into its graph is refused on
   the NPU backends without anyone having to remember the rule exists.

2. **An rknn conversion nobody here has done must say so.** The rknn model
   zoo's documented coverage is YOLOv5–v11; a profile pairing `rknn` with any
   other family (`yolov10`, `rfdetr`, and `yolox`, which no source read here
   places in that range) must declare `experimental: true`. Undocumented is
   not "known broken" — it means the artifact is one nobody in this repo has
   built, which is exactly what the acknowledgement is for.

Both rules need a family to read. A profile that leaves `model_profile:` unset
lets the plugin sniff the family from the model's own tensor shapes, which is
fine — but then there is nothing here to check, so name the family explicitly
on a non-`ort` backend.

## Two things the schema cannot express

Written here rather than invented as validation, because a check that cannot
see what it is checking is worse than a sentence you can read.

**RKNN is sequential.** librknnrt documents no async submission, no batching
and no multi-core orchestration for one model: assume one inference at a time
per model. Nothing in a profile can say otherwise — there is no batch size and
no concurrency field — so this is a sizing fact, not a setting. If an rk3566
band looks achievable only by overlapping inferences, it is not achievable.

**A fixed-geometry artifact pins `input_size:` and nothing here can check
it.** Both NPU backends compile the model at one input geometry, so an
`input_size:` that disagrees with the compiled artifact is wrong in a way the
host cannot detect: it cannot open an `.rknn` to look. Set it to the geometry
you converted at. On `ort` the same field means something looser — RF-DETR
exports leave their spatial axes dynamic, which is why `rfdetr` needs an
explicit `--input-size` and why the plugin refuses to guess one.

## Errors you will meet

Everything below fails the whole config load and names the profile it came
from — at boot that is a refusal to start, on Reload it is a rejected file with
the running config kept. Message shapes as they are emitted:

```
profile my-board: unknown backend "hailo" (ort, qnn or rknn)
profile my-board: unknown model_profile "yolov12" (rfdetr, yolov10,
  yolov8 (or yolov9, yolo11, yolov11, yolo26), yolox)
profile my-board: unknown decoder "cuda" (auto, nvdec, qsv, sw, v4l2, vaapi or
  videotoolbox) — decoder: is the video decode path; the inference runtime is
  backend:
profile my-board: name "other" does not match its filename — the filename is
  the name; drop the key or make them agree
profile my-board: fps_band must be [min, max] with 0 < min <= max, got [4, 2]
profile my-board: sample_fps must be an integer between 1 and 30, got "fast"
profile my-board: sample_fps 6 contradicts fps_band [8, 12] — a declared
  sample_fps must fall inside its own fps_band
profile my-board: tracking.bbd must be true, false or a params mapping, got 1
profile my-board: rknn conversion is undocumented for model_profile rfdetr
  (docs/npu-backends.md covers the model zoo's YOLOv5–v11) — declare
  experimental: true to ship a profile whose artifact nobody here has converted
profile my-board: model artifact models/gone.rknn does not exist or is not a
  regular file (relative paths resolve against the working directory the plugin
  is spawned from)
profile my-board: labels file models/gone.names does not exist or is not a
  regular file …
```

And the ones about attaching it, which name the plugin group instead:

```
plugin detect: unknown profile "rk3566" — no such file in priv/profiles or any
  profile_dirs entry
plugin detect: profile my-board uses backend rknn, which is experimental
  — only ort is proven in soak, and a profile naming another backend must
  declare experimental: true
plugin detect: profile my-board uses backend rknn, which is experimental
  — set allow_experimental: true on this plugin group to run it anyway
plugin detect: profile my-board names no model.rknn artifact for its rknn
  backend — the engine takes its model from the profile alone
```

And warnings, which do not fail the load:

```
profile rk3576: /etc/cairn/profiles/rk3576.yml shadows a previously loaded
  profile of the same name
plugin detect: profile my-board supersedes the global tracking.bbd/oru/ocr
  flags for its cameras — the profile's stage list wins
tracking.reid has no effect for group detect: its profile my-board lists no
  bbd stage
camera front: track: has no effect at tier 1 — tier 1 runs no tracker and
  persists no track rows; record: gates presence recordings
```

A profile's *files* are checked only for a profile some group actually runs, so
a board profile for hardware this node does not have costs it nothing. That is
what makes shipping four of them reasonable.

There is one more class of error you are unlikely to see: an illegal stage
composition (`Cairn.Tracker.Stage.validate_lists/1` — adjacency, pairing and
terminal-position constraints). A `tracking:` block cannot express one, since
presence is all it says; the validator is there because the stage list is the
thing a future profile format would let you write, and a tracker has no error
channel to refuse one at runtime.

## Contributing a board profile

**A new board needs no code change.** Write the file, drop it in a
`profile_dirs:` directory, restart or hit Reload. Everything the file names is
already in the code: if it loads, every value in it is one cairn implements. If
it does not load, the error says which value is not.

The path into the repo is the same file: if the board is one others will meet,
open a PR adding it to `priv/profiles/` — that is a data change, and the review
is about whether the claims in it are true, not about whether the code can run
it. Follow what the shipped four do:

- say in a comment **why** the profile is experimental, in the file itself;
- say what each `fps_band` number was derived from, and that it is pending
  on-hardware measurement;
- write placeholder artifact paths (nobody else has your compiled model), and
  say what toolchain produces them;
- say what a stage choice is grounded in — and, where it is a decision rather
  than a measurement, say that too;
- for a ladder file, give every `engine_budget` its provenance (`measured`
  from a boundary capacity-ladder run, or `provisional` with the arithmetic
  it came from) and mark the file DRAFT while any NON-pack budget is
  provisional — the test suite refuses a shipped ladder without the notes
  (D-L6; pack rungs keep provisional notes until their packs ship).
  `qcs6490-tier1.yml` is the worked example.

Changing a *shipped* profile is a behaviour change for everyone running that
board. Adding a comment or correcting a band is cheap; changing a stage set
should carry the measurement that justifies it.

## Migrating from `tracking.bbd` / `tracking.oru` / `tracking.ocr`

Nothing breaks and there is no deadline. The three global booleans keep working
exactly as they did for every camera whose group has no profile.

What changes is what they are *for*. They were introduced as fleet-wide rollout
switches for matcher/filter/recovery behaviours, global-only because a fleet
where half the cameras associate one way and half the other was not something
an operator could reason about. A profile is that reasoning: it splits the
fleet by *hardware*, per plugin group, with a file naming which board it is
talking about. So the booleans are now the unprofiled path — still the whole
answer for a homogeneous fleet, and superseded per group by anything that
names a profile.

For a **profiled** group the booleans are ignored entirely; the profile's
`tracking:` block is the stage list. Setting both is legal and produces a
warning per profiled group saying which side wins. The rule is presence: a
stage the profile does not list does not run, whatever the global flags say.

To migrate a fleet that runs `tracking.bbd: true` / `oru: true` today:

1. Copy `priv/profiles/generic-ort.yml` into a `profile_dirs:` directory under
   a name of your own, and point its `model:`/`labels:` at your artifacts.
2. Add `bbd: true` and `oru: true` to its `tracking:` block — the shipped
   `generic-ort` deliberately lists neither, since it is the profile that
   changes nothing on adoption.
3. Name it from the group (`profile: my-fleet`).
4. Reload. Check the warnings: if you left the global booleans set you will be
   told, per group, that the profile won.

Then remove the globals when every group is profiled — or leave them, if some
group is not.

## What cairn ships

Four profiles in `priv/profiles/`, each with its reasoning in the file:

| profile | backend | rate | stages | notes |
|---|---|---|---|---|
| `generic-ort` | `ort` | band 5–5 | twin gate only | today's behaviour, named; the migration target and the one non-experimental profile |
| `rk3566-lowfps` | `rknn` | band 2–4 | bbd, oru, twin gate | the low-fps set; wants `--track-floor-json` alongside it |
| `rk3576` | `rknn` | band 8–16 | bbd, oru, twin gate | same pipeline, faster board; the band is scaled from rk3566's and **unmeasured** |
| `qcs6490-tier1` | `qnn` | derived per rung | none (tier 1 — no tracker) | the model-ladder file: six rungs serving both installation states (yolo26 packs installed, or only the baked Apache models — yolox_m carries small fleets there), claim 40 cameras; tiny/nano boundary-measured, the rest provisional |

Three of the four are `experimental: true` for the same blunt reason: their
backends have not proven out in soak. Only `ort` runs today; `rknn` (a stub)
and `qnn` (executes, unsoaked) parse everywhere, and a group naming one
refuses to load without your `allow_experimental: true`.

A group that named the retired `qcs6490` placeholder now fails with
"unknown profile" — point it at `qcs6490-tier1`. The placeholder was a
fixed-model sketch on a backend that did not yet execute; the ladder file
is the board's shipping config.
