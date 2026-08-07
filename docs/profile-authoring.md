# Writing a hardware profile

A **profile** is one YAML file that names, in one place, everything about how
a piece of hardware runs detection: which model artifact, which family, which
inference runtime, what frame rate to expect, and which tracker stages to run
behind it. A plugin group names its profile; config load expands that one file
into *both* halves of the boundary — the plugin's model argv and the host's
tracker stage list — so the two cannot disagree with each other.

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
    command: plugins/cairn-detect/target/release/cairn-detect
    # The profile's filename, without .yml.
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

The group's `command:` keeps everything that describes *your* deployment — the
binary's path, `--motion-json`, `--track-floor-json` — and loses everything
that describes the model. A profiled group whose command already carries
`--model`, `--model-profile`, `--input-size`, `--decoder`, `--labels` or
`--sample-fps` fails the load: those six come from the profile alone, so that
there is never a question of which answer won.

## The schema

Every key, annotated. All are optional except that a profile which some group
actually runs must name an artifact for its own backend.

```yaml
# <profile_dirs entry>/my-board.yml
name: my-board             # optional; when present it must equal the filename
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

## The menus, and where each lives in code

| field | menu | where the menu lives |
|---|---|---|
| `backend` | `ort`, `rknn`, `qnn` | `BackendKind`, `plugins/cairn-detect/src/infer/backend.rs` — mirrored in `Cairn.Config.Profile`'s capability table |
| `model_profile` | `yolox`, `yolov10` (or `yolo26`), `yolov8` (or `yolov9`, `yolo11`, `yolov11`), `rfdetr` (or `rf-detr`) | `PROFILES`, `plugins/cairn-detect/src/infer/catalog.rs` |
| `decoder` | `auto`, `vaapi`, `qsv`, `nvdec`, `v4l2`, `videotoolbox`, `sw` | `DecoderKind`, `plugins/cairn-detect/src/decode.rs` |
| `tracking:` stage keys | `bbd`, `oru`, `ocr`, `twin_mint` | `Cairn.Tracker.Stage.Bbd` / `.Oru` / `.Ocr` / `.TwinMint` |

Aliases are names, not families: `yolo11` and `yolov8` are the same catalog row
(several Ultralytics generations export byte-identical tensor layouts), and the
error messages say which family an alias resolves to.

`decoder:` and `backend:` are different knobs that both sound like "how do I
run this fast". `decoder:` is the **video** path — how H.264 frames get
decoded, probed at plugin startup with a software fallback. `backend:` is the
**inference** path — what executes the model. Naming a hardware video decoder
says nothing about where the model runs.

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
  with no stage keys at all means "run nothing", which is a real choice: it is
  how `qcs6490.yml` turns off the cold-start twin gate that every other
  profile leaves on.
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
`stationary_after_ms` — *are* read. They resolve camera → profile → global: a
camera's own override outranks its group's profile, and the profile's
band-tuned value outranks the global default. They are validated against the
same ranges the global keys are.

Two flags stay outside profiles on purpose (D-P6): `--motion-json` and
`--track-floor-json` describe the *scene* rather than the model, so they remain
your own argv in the group's `command:`. This matters for `bbd`, whose measured
win is a composition with the track floor — with the floor off it bought
nothing at all, because an expired track has no row left to admit against.

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
profile my-board: unknown model_profile "yolov12" (rfdetr (or rf-detr), yolov10
  (or yolo26), yolov8 (or yolov9, yolo11, yolov11), yolox)
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
plugin detect: command carries --input-size, which profile my-board owns — a
  profiled group's model flags (--model, --model-profile, --input-size,
  --decoder, --labels, --sample-fps) come from its profile alone; drop
  --input-size from command:
plugin detect: profile my-board uses backend rknn, which is experimental
  — only ort is proven in soak, and a profile naming another backend must
  declare experimental: true
plugin detect: profile my-board uses backend rknn, which is experimental
  — set allow_experimental: true on this plugin group to run it anyway
plugin detect: profile my-board names no model.rknn artifact for its rknn
  backend — a profiled group takes --model from its profile alone
```

Two warnings, which do not fail the load:

```
profile rk3576: /etc/cairn/profiles/rk3576.yml shadows a previously loaded
  profile of the same name
plugin detect: profile my-board supersedes the global tracking.bbd/oru/ocr
  flags for its cameras — the profile's stage list wins
tracking.reid has no effect for group detect: its profile my-board lists no
  bbd stage
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
  than a measurement, say that too. `qcs6490.yml` is the worked example of the
  awkward case: it delists the twin gate on a rule, states that the gate exists
  because of the very same detector class, and tells an operator what to add
  back if the trade falls the other way in their scene.

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
3. Name it from the group (`profile: my-fleet`) and drop the model flags out
   of that group's `command:`; keep `--motion-json` / `--track-floor-json`.
4. Reload. Check the warnings: if you left the global booleans set you will be
   told, per group, that the profile won.

Then remove the globals when every group is profiled — or leave them, if some
group is not.

## What cairn ships

Four profiles in `priv/profiles/`, each with its reasoning in the file:

| profile | backend | band (declared) | stages | notes |
|---|---|---|---|---|
| `generic-ort` | `ort` | 5–5 | twin gate only | today's behaviour, named; the migration target and the one non-experimental profile |
| `rk3566-lowfps` | `rknn` | 2–4 | bbd, oru, twin gate | the low-fps set; wants `--track-floor-json` alongside it |
| `rk3576` | `rknn` | 8–16 | bbd, oru, twin gate | same pipeline, faster board; the band is scaled from rk3566's and **unmeasured** |
| `qcs6490` | `qnn` | 15–30 | none | NMS-free family by requirement; twin gate delisted (D-P8) |

Three of the four are `experimental: true` for the same blunt reason: their
backends do not execute yet. Only `ort` runs today; `rknn` and `qnn` parse
everywhere, and a group naming one refuses to load without your
`allow_experimental: true`.
