defmodule Cairn.Config.Profile do
  @moduledoc """
  A hardware profile: one YAML file naming choices from menus the code
  exposes, attached to a plugin group by name (`profile: <name>` on an entry
  of `plugins:`).

  A profile is **data composing curated code**, not free knob tuning: every
  field names something that already exists — a Rust model family, a
  backend, a tracker stage. Config load enforces the shape of that naming:
  unknown keys, malformed bands, illegal stage compositions, and the type of
  every field the model half reads (`model:` a mapping of path strings,
  `model_profile:`/`decoder:`/`labels:` strings, `experimental:` a boolean)
  are rejected here. So are names outside the menus the plugin itself
  accepts — `backend:` against the capability table below, `model_profile:`
  against the Rust catalog's families and aliases, `decoder:` against the
  video decode kinds — and the two backend/family combinations
  `docs/npu-backends.md` calls out, one broken and one unverified (see
  `check_capabilities/5`).
  `Cairn.Config` rejects a profiled group whose model artifact or labels file
  is missing, or whose backend is stubbed (see "Rust argv" below).
  Profiles are files, never inline config: shipped ones live
  in `priv/profiles/*.yml` — the four board profiles cairn ships — operator
  ones in the directories the top-level `profile_dirs:` key lists, and an
  operator file wins a name collision with a shipped one (with a warning
  saying so).

  `docs/profile-authoring.md` is the operator-facing half of this module: the
  menus, the errors, and the two rules the schema cannot express.

  ## Schema

  Every key. The four profiles cairn ships are worked examples of it, with
  their reasoning in their own comments:

  ```yaml
  # <a profile_dirs entry>/example.yml
  name: example              # optional; must match the filename when present
  tier: 2                    # optional; the capability this profile claims —
                             # 1 = presence detection, 2 = accurate MOT.
                             # Absent = no tier semantics (today's behavior).
  experimental: false        # true before any group may run a non-ort backend
  backend: ort               # ort | rknn | qnn — qnn executes behind the
                             # experimental gate; rknn is still a stub
  model:                     # per-backend artifact paths
    onnx: models/yolox_nano.onnx
  model_profile: yolox       # Rust catalog family name
  input_size: 416
  decoder: auto              # the video decode path, not the backend
  labels: models/coco.names
  fps_band: [4, 8]           # declared, not measured (D-P5)
  sample_fps: 6              # optional; emits --sample-fps when set. fps_band
                             # validates it but a band alone emits nothing (D-P4)
  tracking:                  # stage presence + params, plus band-tuned bounds
    bbd: true                # listed; a params mapping lists it too (and no
                             # shipped stage reads one — see `stages/1`)
    oru: { }                 # equivalent to true
    ocr: true                # observation-centric recovery; listed the same way
    twin_mint: true          # presence, not a default — omit to delist
    max_unseen_ms: 3000
    max_live_tracks: 128
    stationary_after_ms: 10000
    tracker: cairn          # which tracker core the group's cameras run
  ```

  A LADDER profile is the other shape, and the two never mix in one file:
  `model_ladder:` is mutually exclusive with `model:`/`input_size:`/
  `sample_fps:`/`fps_band:`, because the resolved rung is the model and the
  rate is derived from its budget (D-L4). It requires `tier: 1` and
  `supported_cameras:`:

  ```yaml
  # <a profile_dirs entry>/ladder-example.yml
  tier: 1
  backend: qnn
  experimental: true
  labels: models/coco.names   # shared by every rung, like decoder:
  model_ladder:               # ordered most accurate first — the AUTHOR's
    - model:                  # claim, unchecked; engine_budget is measured
        qnn: packs/26m.onnx   # passes/s, strictly increasing down the list
      model_profile: yolo26   # a rung's own family; absent = the top-level one
      input_size: 640
      engine_budget: 17
      pack: yolo26m           # skipped (warned) while its artifact is absent
    - model:
        qnn: models/nano.onnx
      model_profile: yolox
      input_size: 416
      engine_budget: 75
  supported_cameras: 40       # the support CLAIM, enforced as a bound; the
                              # non-pack rungs alone must cover it (Apache-
                              # complete) = the last non-pack rung's reach
  ```

  Resolution is static, at config load: `Cairn.Config.resolve_ladders/2`
  picks the first rung whose budget covers the configured fleet and derives
  each camera's `sample_fps` from it.

  The `tracking:` block expresses **presence, not order** (D-P2): a stage
  key present means listed, absent means not, and the tracker's fixed
  insertion points decide where each runs. The block itself is the stage
  list — present-but-empty means "run nothing", while omitting the block
  entirely means the profile says nothing about tracking and the camera's
  boolean flags stand. The translated lists are
  validated against every stage's declared constraints at load
  (`Cairn.Tracker.Stage.validate_lists/1`) — an illegal composition fails
  the config load, since the tracker has no error channel.

  ## The model half

  The six model fields render once, through `native_config/1`, into the
  in-VM engine's init config (`Cairn.Native.Config.normalize/1`'s
  vocabulary): the `model:` entry for this profile's own backend,
  `model_profile`, `input_size`, `decoder`, `labels`, `sample_fps`.
  `model/1` is the shared table `native_config/1` and validation both walk.
  (Until membrane port phase 6 the same table also rendered a plugin argv;
  that path is gone.)

  An unset field is dropped, leaving the crate's own default or its
  sniffing in force. `sample_fps` is the one field `fps_band:` never fills
  in: the band only validates a declared `sample_fps:` (D-P4) — it is
  never the source of the value, so a profile with a band and no
  `sample_fps:` still passes nothing. The profile is the **single source**
  of those six (D-P4); the motion and track-floor scene knobs are not among
  them and stay operator-owned (D-P6).

  Three things `Cairn.Config` refuses at load, which is where an operator
  reads diagnostics: a `model:` artifact that is not on disk, a `labels:`
  file that is not on disk, and a group running a backend other than `ort`
  — experimental until proven in soak, whether the engine executes it (qnn)
  or stubs it (rknn) (D-P10) — unless the profile declares
  `experimental: true` *and* the group sets `allow_experimental: true`. The two file paths are checked only for a
  profile some group actually runs, so a board profile for hardware this node
  does not have costs it nothing.

  Parsed on `Cairn.Config`'s `add_error/2`/`add_warning/2` contract like
  its `Camera`/`PluginGroup` siblings.
  """

  alias Cairn.Config
  alias Cairn.Tracker.Stage

  @known_keys ~w(name experimental backend model model_profile input_size decoder labels
                 fps_band sample_fps tracking tier model_ladder supported_cameras)
  @known_rung_keys ~w(model model_profile input_size engine_budget pack)
  @known_tracking_keys ~w(bbd oru ocr twin_mint max_unseen_ms max_live_tracks stationary_after_ms
                          tracker)
  # What each backend accepts, as static data — the Elixir half of
  # `BackendKind::capabilities` in
  # `plugins/cairn-detect/src/infer/backend.rs`, which names this table as its
  # host-side mirror. Both sides are *claims* about a runtime rather than
  # probes of one, and the evidence for each row (established by
  # `docs/npu-backends.md` against conservative reading) is written out on
  # the Rust rows; this side carries the same values because config load has to
  # answer the same questions with no plugin running and, for a board profile
  # written ahead of its hardware, no such device attached.
  #
  # `artifact` is the `model:` **key** naming this backend's compiled file, not
  # that file's format, and the two deliberately disagree for qnn: Rust reports
  # `ArtifactFormat::Onnx` there because QNN is an onnxruntime execution
  # provider, while the key here is `qnn:` because the QDQ graph it loads is a
  # different *file* from the fp32 export. Neither is a stale copy of the
  # other. Backends consume different formats (prior-art §1), so a profile
  # ships one artifact per backend and the profile's own backend picks which
  # path becomes `--model`.
  #
  # `dynamic_shapes` is mirrored and read by no rule: what it would refuse — an
  # `input_size:` that disagrees with a fixed-geometry artifact — is a fact
  # about a compiled file the host cannot open, so a check here could only
  # guess. It is in the authoring guide instead (`docs/profile-authoring.md`),
  # beside the RKNN-sequential note, which the schema cannot express either.
  @backend_capabilities %{
    "ort" => %{artifact: "onnx", fused_nms: true, dynamic_shapes: true},
    "rknn" => %{artifact: "rknn", fused_nms: false, dynamic_shapes: false},
    "qnn" => %{artifact: "qnn", fused_nms: false, dynamic_shapes: false}
  }
  # Derived rather than repeated so a backend cannot be added to one list and
  # forgotten in the other.
  @backend_artifacts Map.new(@backend_capabilities, fn {backend, caps} ->
                       {backend, caps.artifact}
                     end)
  @backends Map.keys(@backend_artifacts)
  @known_model_keys Map.values(@backend_artifacts)

  # The Rust catalog's model families, row for row with `PROFILES` in
  # `plugins/cairn-detect/src/infer/catalog.rs` — aliases included, so
  # `model_profile:` is checked against the same set the plugin's own
  # `ModelProfile::parse` accepts — plus the two columns profile validation
  # reads:
  #
  #   * `nms:` — where suppression happens. `:none` is an NMS-free head (Rust's
  #     `nms: None`: yolov10's end-to-end head, rfdetr's queries); `:host_side`
  #     is cairn's own suppression in the plugin's `heads` (`DEFAULT_NMS`),
  #     which runs on the CPU whatever executed the model; `:fused` is a family
  #     whose export carries the NMS op *inside the graph*. **No shipped family
  #     is `:fused`** — every catalog row is one of the first two — so the
  #     fused-NMS rule in `check_capabilities/5` cannot fire from today's menu.
  #     It is data rather than a comment so that a family added later with a
  #     fused export is refused on the NPU backends without anyone having to
  #     remember the rule was here.
  #   * `rknn_conversion:` — whether anything in `docs/npu-backends.md`
  #     documents converting this family with rknn-toolkit2. `:documented` is
  #     the model zoo's stated YOLOv5–v11 coverage; `:undocumented` is
  #     everything else, which the research names outright for yolov10 and
  #     DETR-class and which yolox falls into by silence (Megvii's, outside
  #     that range, placed there by no source read here). Undocumented is not
  #     "known broken" — it is "nobody in this repo has converted one", which
  #     is what `experimental: true` acknowledges.
  @model_families %{
    "yolox" => %{aliases: [], nms: :host_side, rknn_conversion: :undocumented},
    "yolov10" => %{aliases: ["yolo26"], nms: :none, rknn_conversion: :undocumented},
    "yolov8" => %{
      aliases: ["yolov9", "yolo11", "yolov11"],
      nms: :host_side,
      rknn_conversion: :documented
    },
    "rfdetr" => %{aliases: ["rf-detr"], nms: :none, rknn_conversion: :undocumented}
  }

  # `decoder:`'s menu, mirroring `DecoderKind` in
  # `plugins/cairn-detect/src/decode.rs`. This is the **video** decode path and
  # not `backend:`'s inference one; the plugin's own flag help draws the same
  # distinction. Checked here because clap rejects an unknown value as a usage
  # error, which reaches an operator as a plugin that will not start and a
  # restart loop rather than as a config error naming the typo.
  @decoders ~w(auto vaapi qsv nvdec v4l2 videotoolbox sw)
  @stage_modules %{
    "bbd" => {:bbd, Stage.Bbd},
    "oru" => {:oru, Stage.Oru},
    "ocr" => {:ocr, Stage.Ocr},
    "twin_mint" => {:twin_mint, Stage.TwinMint}
  }

  # The ascending capability ladder (`tier:`): 1 is presence detection, 2 is
  # accurate MOT + persistence; higher rungs are reserved for capabilities
  # that do not exist yet (ALPR, facial identification, …), so validation
  # names the rungs that ship today and widens as they do — the schema shape
  # never changes. Distinct from `Camera.tier()`, the per-label score
  # thresholds `policy/2` carries as `:track`/`:record`: that word predates
  # this ladder and names a different axis.
  @tiers [1, 2]

  # The model ladder's rate bounds, tier by tier. Both numbers are nominal
  # SampleGate rates; resolution divides budgets against the EFFECTIVE rate
  # (`effective_rate/1`) because the gate quantizes to the frame grid —
  # "2 fps" delivers 1.875/s, and 40 × 1.875 = 75.0 is exactly the measured
  # nano budget, where the nominal 2 would refuse the measured fleet
  # (tier1-capacity-20260814). Tier 2 has no row on purpose: its floor waits
  # on bar-verified rungs (tier2-accuracy), so `model_ladder` is refused
  # there rather than resolved against a floor nobody measured.
  @ladder_floors %{1 => %{floor_fps: 2, cap_fps: 10}}

  # The substream frame grid the capacity campaign measured on (true 15 fps,
  # pts deltas uniformly 6000/90kHz). `effective_rate/1` is a claim about
  # this grid; a fleet on a different substream rate shifts the effective
  # rates, which the authoring guide says to an author's face.
  @substream_grid_fps 15

  defstruct name: nil,
            tier: nil,
            experimental: false,
            backend: "ort",
            model: %{},
            model_profile: nil,
            input_size: nil,
            decoder: nil,
            labels: nil,
            fps_band: nil,
            sample_fps: nil,
            # The ordered rung list (`model_ladder:`), nil for a single-model
            # profile, and the camera count it claims. `resolved_rung` is
            # written by `Cairn.Config`'s load-time resolution, never parsed:
            # the selected rung's map, whose model fields are also lowered
            # into the five above so everything downstream reads a ladder
            # profile as the single-model profile it resolved to.
            model_ladder: nil,
            supported_cameras: nil,
            resolved_rung: nil,
            # The stage presence map (atom key → params map), nil when the
            # file had no `tracking:` block at all — absence speaks (see the
            # moduledoc) — plus the three band-tuned tracker bounds and the
            # tracker core the group runs (nil where the file set none).
            stages: nil,
            max_unseen_ms: nil,
            max_live_tracks: nil,
            stationary_after_ms: nil,
            tracker: nil

  @type t :: %__MODULE__{}

  @typedoc """
  One backend's row of the capability table: the `model:` key its artifact is
  named under, whether it runs an export with the NMS op fused into the graph,
  and whether it accepts a graph that leaves a spatial dim symbolic.
  """
  @type capabilities :: %{
          artifact: String.t(),
          fused_nms: boolean(),
          dynamic_shapes: boolean()
        }

  @typedoc """
  One model family's row: the `model_profile:` spellings that resolve to it,
  where its suppression happens, and whether its rknn conversion is documented.
  """
  @type family :: %{
          aliases: [String.t()],
          nms: :fused | :host_side | :none,
          rknn_conversion: :documented | :undocumented
        }

  @doc """
  What `backend` accepts, from the table mirroring the plugin's own.

  Raises on a backend outside the schema's menu — every caller has already had
  `check_backend/3` reject one.
  """
  @spec capabilities(String.t()) :: capabilities()
  def capabilities(backend), do: Map.fetch!(@backend_capabilities, backend)

  @doc """
  The catalog family `name` resolves to (aliases included), or `nil` for a name
  no family claims.

  Trimmed and downcased exactly as the plugin's `ModelProfile::parse` does, so
  a name this accepts is one the plugin accepts.
  """
  @spec family(term()) :: {String.t(), family()} | nil
  def family(name) when is_binary(name) do
    wanted = name |> String.trim() |> String.downcase()

    Enum.find(@model_families, fn {canonical, row} ->
      wanted == canonical or wanted in row.aliases
    end)
  end

  def family(_other), do: nil

  @doc """
  The `model:` key naming `backend`'s compiled artifact — the one this
  profile's `--model` is read from.
  """
  @spec artifact_key(String.t()) :: String.t()
  def artifact_key(backend), do: Map.fetch!(@backend_artifacts, backend)

  @doc "The ladder rate bounds for `tier`, or `nil` for a tier no ladder ships on."
  @spec ladder_floor(term()) :: %{floor_fps: pos_integer(), cap_fps: pos_integer()} | nil
  def ladder_floor(tier), do: Map.get(@ladder_floors, tier)

  @doc """
  The rate `Cairn.Pipeline.SampleGate` actually delivers for a nominal `fps`
  on the measured substream grid: admissions land on frame slots, so the gate
  opens every `ceil(grid / fps)` frames — "2 fps" is 1.875/s. An exact
  divisor (5 → every 3rd frame) is returned undamped although jitter
  measurably degrades it (4.17/s for "5 fps"); overstating demand is the
  conservative side for budget arithmetic. Ladder resolution divides every
  budget against this, never against the nominal rate.
  """
  @spec effective_rate(pos_integer()) :: float()
  def effective_rate(fps) when is_integer(fps) and fps > 0,
    do: @substream_grid_fps / ceil(@substream_grid_fps / fps)

  @doc """
  The model artifact path this profile names for its own backend, or `nil`
  when it names none.

  Verbatim, not resolved: the path is handed to the plugin process as
  `--model` and read there, so anything that rewrote it here would check one
  file and pass the plugin another.
  """
  @spec artifact(t()) :: String.t() | nil
  def artifact(%__MODULE__{backend: backend, model: model}),
    do: Map.get(model, artifact_key(backend))

  # The six model decisions a profile owns. `--motion-json`/
  # `--track-floor-json` equivalents are absent on purpose: they describe
  # the scene, not the model (D-P6).
  @model_fields [
    :model,
    :model_profile,
    :input_size,
    :decoder,
    :labels,
    :sample_fps
  ]

  @doc """
  The model half of the file as fields, `nil` for each one the profile left
  unset — the single source `native_config/1` renders.
  """
  @spec model(t()) :: %{atom() => String.t() | pos_integer() | nil}
  def model(%__MODULE__{} = profile) do
    Map.new(@model_fields, fn field -> {field, model_field(profile, field)} end)
  end

  # The file's `model:` is a mapping of per-backend paths; the rendering
  # carries the one path this profile's own backend loads.
  defp model_field(profile, :model), do: artifact(profile)
  defp model_field(profile, field), do: Map.fetch!(profile, field)

  @doc """
  The model decisions in `Cairn.Native.Config.normalize/1`'s vocabulary, for
  the in-VM engine.

  An unset field is dropped rather than passed as `nil`: `normalize/1` then
  defaults it, and the two of the six with a default (`decoder: "auto"`,
  `sample_fps: 5`) take the crate's own clap values.

  `backend:` rides along here; it is not one of the six model fields.
  """
  @spec native_config(t()) :: map()
  def native_config(%__MODULE__{} = profile) do
    profile
    |> model()
    |> Map.reject(fn {_field, value} -> is_nil(value) end)
    |> Map.put(:backend, profile.backend)
  end

  @doc """
  Loads every `*.yml` under the shipped dir and the operator dirs into a
  name → profile map.

  Later dirs win name collisions — `Cairn.Config` passes the shipped dir
  first and operator `profile_dirs:` after, so an operator file shadows a
  shipped one — and each collision is warned about by name, since a silently
  shadowed profile is how a fleet ends up running settings nobody can find
  in a file they are reading.
  """
  @spec load_dirs([Path.t()], map()) :: {%{String.t() => t()}, map()}
  def load_dirs(dirs, acc) do
    Enum.reduce(dirs, {%{}, acc}, fn dir, {profiles, acc} ->
      dir |> Path.join("*.yml") |> Path.wildcard() |> Enum.sort() |> load_files(profiles, acc)
    end)
  end

  defp load_files(paths, profiles, acc) do
    Enum.reduce(paths, {profiles, acc}, fn path, {profiles, acc} ->
      name = Path.basename(path, ".yml")

      case load_file(path, name, acc) do
        {nil, acc} ->
          {profiles, acc}

        {profile, acc} ->
          {Map.put(profiles, name, profile), warn_shadow(acc, profiles, name, path)}
      end
    end)
  end

  # Warned only once the shadowing file actually parsed: a broken shadow
  # leaves the original in force, and a warning claiming otherwise would send
  # the operator hunting the wrong file.
  defp warn_shadow(acc, profiles, name, path) do
    if Map.has_key?(profiles, name) do
      Config.add_warning(
        acc,
        "profile #{name}: #{path} shadows a previously loaded profile of the same name"
      )
    else
      acc
    end
  end

  defp load_file(path, name, acc) do
    case YamlElixir.read_from_file(path) do
      {:ok, raw} -> parse(raw, name, acc)
      {:error, err} -> {nil, Config.add_error(acc, "profile #{name}: #{Exception.message(err)}")}
    end
  end

  @doc false
  @spec parse(term(), String.t(), map()) :: {t() | nil, map()}
  def parse(raw, name, acc) when is_map(raw) do
    acc = Config.warn_unknown(acc, raw, @known_keys, "profile #{name}")

    acc =
      Config.warn_unknown(
        acc,
        Map.get(raw, "tracking"),
        @known_tracking_keys,
        "profile #{name} tracking"
      )

    acc =
      Config.warn_unknown(acc, Map.get(raw, "model"), @known_model_keys, "profile #{name} model")

    errors_before = length(acc.errors)

    acc =
      acc
      |> check_name(raw, name)
      |> check_backend(raw, name)
      |> check_pos_int(raw, "input_size", name)
      |> check_fps_band(raw, name)
      |> check_sample_fps(raw, name)
      |> check_tracking(raw, name)
      |> check_model(raw, name)
      |> check_string(raw, "model_profile", name)
      |> check_string(raw, "decoder", name)
      |> check_string(raw, "labels", name)
      |> check_experimental(raw, name)
      |> check_model_profile(raw, name)
      |> check_decoder(raw, name)
      |> check_capability_rules(raw, name)
      |> check_tier(raw, name)
      |> check_model_ladder(raw, name)
      |> check_supported_cameras(raw, name)
      |> check_ladder_coverage(raw, name)

    if length(acc.errors) > errors_before do
      {nil, acc}
    else
      tracking = Map.get(raw, "tracking")

      profile = %__MODULE__{
        name: name,
        tier: Map.get(raw, "tier"),
        experimental: Map.get(raw, "experimental") || false,
        backend: Map.get(raw, "backend", "ort"),
        model: Map.get(raw, "model") || %{},
        model_profile: Map.get(raw, "model_profile"),
        input_size: Map.get(raw, "input_size"),
        decoder: Map.get(raw, "decoder"),
        labels: Map.get(raw, "labels"),
        fps_band: Map.get(raw, "fps_band"),
        sample_fps: Map.get(raw, "sample_fps"),
        model_ladder: rungs(Map.get(raw, "model_ladder")),
        supported_cameras: Map.get(raw, "supported_cameras"),
        stages: stages(tracking),
        max_unseen_ms: tracking && Map.get(tracking, "max_unseen_ms"),
        max_live_tracks: tracking && Map.get(tracking, "max_live_tracks"),
        stationary_after_ms: tracking && Map.get(tracking, "stationary_after_ms"),
        tracker: tracking && Map.get(tracking, "tracker")
      }

      validate_stage_lists(profile, acc)
    end
  end

  def parse(_raw, name, acc) do
    {nil, Config.add_error(acc, "profile #{name}: must be a YAML mapping")}
  end

  # The presence map the tracker's policy path consumes: an atom key per
  # listed stage, its params map as the value. `true` is shorthand for
  # "listed with defaults" (an empty params map); `false` and absence both
  # mean not listed — presence, not defaults. Params keep their YAML string
  # keys: a stage would read its own vocabulary off them, and converting
  # operator-authored keys to atoms would be manufacturing atoms from input.
  # None of the four stages reads its params today — each takes its constants
  # from its own module — so a params mapping parses, reaches the stage and
  # changes nothing. `docs/profile-authoring.md` says so to an author's face,
  # where it matters more than here.
  #
  # A profile with no `tracking:` block at all gets `nil`, not an empty map:
  # the block *is* the stage list, so its presence — even empty — speaks
  # ("run nothing"), while its absence means the profile said nothing about
  # tracking and the camera's boolean path stands. Without that distinction a
  # backend-only profile would silently delist the twin gate.
  defp stages(nil), do: nil

  defp stages(tracking) do
    Enum.reduce(@stage_modules, %{}, fn {key, {atom, _module}}, stages ->
      case Map.get(tracking, key) do
        true -> Map.put(stages, atom, %{})
        params when is_map(params) -> Map.put(stages, atom, params)
        _absent_or_false -> stages
      end
    end)
  end

  # The Phase 2 validator, fed the exact lists the tracker's translation will
  # build from this profile — the transitional home moving to its permanent
  # one: a failed composition is a failed config load.
  defp validate_stage_lists(profile, acc) do
    lists = %{
      association_one: stage_entry(profile, :bbd),
      association_two: stage_entry(profile, :bbd),
      minting: stage_entry(profile, :twin_mint),
      per_object: stage_entry(profile, :oru),
      recovery: stage_entry(profile, :ocr)
    }

    case Stage.validate_lists(lists) do
      :ok -> {profile, acc}
      {:error, message} -> {nil, Config.add_error(acc, "profile #{profile.name}: #{message}")}
    end
  end

  defp stage_entry(profile, key) do
    {^key, module} = Map.fetch!(@stage_modules, Atom.to_string(key))

    case profile.stages && Map.get(profile.stages, key) do
      nil -> []
      params -> [{module, params}]
    end
  end

  defp check_name(acc, raw, name) do
    case Map.get(raw, "name") do
      nil ->
        acc

      ^name ->
        acc

      other ->
        Config.add_error(
          acc,
          "profile #{name}: name #{inspect(other)} does not match its filename — " <>
            "the filename is the name; drop the key or make them agree"
        )
    end
  end

  defp check_backend(acc, raw, name) do
    case Map.get(raw, "backend", "ort") do
      backend when backend in @backends ->
        acc

      other ->
        Config.add_error(
          acc,
          "profile #{name}: unknown backend #{inspect(other)} (#{natural_list(@backends)})"
        )
    end
  end

  # A family this side does not know is one the plugin's own parser would
  # reject at startup; naming the menu here costs the operator a config error
  # instead of a process that exits before it opens its first stream. Skipped
  # for a non-string value — `check_string/4` has already spoken about that.
  defp check_model_profile(acc, raw, name) do
    case Map.get(raw, "model_profile") do
      value when is_binary(value) and value != "" ->
        if family(value) do
          acc
        else
          Config.add_error(
            acc,
            "profile #{name}: unknown model_profile #{inspect(value)} " <>
              "(#{family_menu()})"
          )
        end

      _absent_or_already_reported ->
        acc
    end
  end

  # Aliases shown against the family they resolve to, in the plugin's own
  # `catalog::names` *format*, so an error says what `yolo11` will do. The
  # ordering differs on purpose: Rust renders `PROFILES` declaration order,
  # while a map here has none, so this menu sorts for a deterministic message.
  defp family_menu do
    @model_families
    |> Enum.sort_by(fn {canonical, _row} -> canonical end)
    |> Enum.map_join(", ", fn
      {canonical, %{aliases: []}} -> canonical
      {canonical, %{aliases: aliases}} -> "#{canonical} (or #{Enum.join(aliases, ", ")})"
    end)
  end

  defp check_decoder(acc, raw, name) do
    case Map.get(raw, "decoder") do
      value when is_binary(value) and value != "" ->
        Config.check(
          acc,
          value in @decoders,
          "profile #{name}: unknown decoder #{inspect(value)} " <>
            "(#{natural_list(@decoders)}) — decoder: is the video decode path; " <>
            "the inference runtime is backend:"
        )

      _absent_or_already_reported ->
        acc
    end
  end

  # The two rules `docs/npu-backends.md` §"Known-broken combinations"
  # turns into validation. Both need a backend *and* a family to read: a
  # profile that names no `model_profile:` leaves the family to the plugin's
  # own sniffing, and there is nothing here to check it against — which is
  # itself a reason to name the family on a non-ort backend (the authoring
  # guide says so).
  defp check_capability_rules(acc, raw, name) do
    backend = Map.get(raw, "backend", "ort")

    case {backend in @backends, family(Map.get(raw, "model_profile"))} do
      {true, {_canonical, _row} = family} ->
        # `=== true`, not `|| false`: a non-boolean `experimental:` is already
        # an error (`check_experimental/3`, same pipeline), and treating its
        # truthiness as acknowledgement would swallow the rknn rule's more
        # actionable "declare experimental: true" message alongside it.
        check_capabilities(acc, name, backend, Map.get(raw, "experimental") === true, family)

      _unknown_backend_or_no_family ->
        acc
    end
  end

  @doc false
  # Public only so the fused-NMS rule can be exercised against a family row
  # today's catalog does not contain — see `@model_families`. `family` is the
  # `{name, row}` pair `family/1` returns. Test coverage leans on both rules
  # living in this one function: the rknn rule's fixtures prove the
  # parse→here wiring on the public path, the synthetic fused row proves the
  # NMS branch directly — split the rules apart and each half needs its own
  # public-path test.
  @spec check_capabilities(map(), String.t(), String.t(), boolean(), {String.t(), family()}) ::
          map()
  def check_capabilities(acc, name, backend, experimental, {model_profile, family}) do
    caps = capabilities(backend)

    acc
    |> Config.check(
      family.nms != :fused or caps.fused_nms,
      "profile #{name}: #{backend} backend requires an NMS-free family or host-side-NMS " <>
        "decode, and model_profile #{model_profile} fuses the suppression op into its " <>
        "export — its op is not one this runtime implements, so the graph would be " <>
        "declined at load"
    )
    |> Config.check(
      backend != "rknn" or family.rknn_conversion == :documented or experimental,
      "profile #{name}: rknn conversion is undocumented for model_profile " <>
        "#{model_profile} (docs/npu-backends.md covers the model zoo's YOLOv5–v11) — " <>
        "declare experimental: true to ship a profile whose artifact nobody here has " <>
        "converted"
    )
  end

  # Both tier rules in one place: the menu check (the ladder's shipped rungs,
  # see `@tiers`) and the one cross-field contradiction — a tier-1 profile
  # with a `tracking:` block. Tier 1 is presence detection and its pipeline
  # runs no tracker, so a stage list (the block IS one, even empty — see
  # `stages/1`) describes machinery the tier turns off; failing loud beats a
  # profile that reads as if it tuned something. The value, not the key:
  # a bare `tracking:` parses to nil, which everything here (`stages/1`,
  # `check_tracking/3`) reads as "said nothing about tracking" — the
  # contradiction needs the profile to have actually said something. Tier 2
  # requires nothing extra today — its accuracy claims live in docs until the
  # measured tier files ship.
  defp check_tier(acc, raw, name) do
    case Map.get(raw, "tier") do
      nil ->
        acc

      tier when tier in @tiers ->
        Config.check(
          acc,
          tier != 1 or is_nil(Map.get(raw, "tracking")),
          "profile #{name}: tier 1 is presence detection and runs no tracker — " <>
            "remove the tracking: block or claim tier: 2"
        )

      other ->
        Config.add_error(
          acc,
          "profile #{name}: unknown tier #{inspect(other)} — the capability ladder " <>
            "ships #{natural_list(Enum.map(@tiers, &Integer.to_string/1))} today " <>
            "(1 = presence detection, 2 = accurate MOT); higher rungs are reserved"
        )
    end
  end

  # The struct's rung shape: atom keys, only built once every check passed, so
  # construction may assume the raw shapes are valid. `model_profile` stays
  # nil where a rung leans on the profile-level family; resolution coalesces.
  defp rungs(nil), do: nil

  defp rungs(list) do
    Enum.map(list, fn rung ->
      %{
        model: Map.get(rung, "model"),
        model_profile: Map.get(rung, "model_profile"),
        input_size: Map.get(rung, "input_size"),
        engine_budget: Map.get(rung, "engine_budget"),
        pack: Map.get(rung, "pack")
      }
    end)
  end

  # The ladder schema (D-L4, tier1-ladder plan). List order is the AUTHOR's
  # accuracy claim, most accurate first — nothing here can check mAP — so the
  # one ordering validation is the budgets: strictly increasing down the
  # list, because a later rung exists to buy more capacity and a rung that
  # buys none is dead weight or a misordering.
  defp check_model_ladder(acc, raw, name) do
    case Map.get(raw, "model_ladder") do
      nil ->
        acc

      list when is_list(list) and list != [] ->
        acc
        |> check_ladder_exclusions(raw, name)
        |> check_ladder_tier(raw, name)
        |> check_rungs(list, raw, name)
        |> check_budget_order(list, name)

      other ->
        Config.add_error(
          acc,
          "profile #{name}: model_ladder must be a non-empty list of rungs, " <>
            "got #{inspect(other)}"
        )
    end
  end

  # D-L4: the ladder is the model AND rate authority — a profile declaring
  # any of the four alongside it is contradicting its own resolution, refused
  # in one error naming every offender. `input_size` rides the rule because
  # it is per-rung (640 vs 416 rungs are the normal case), so a top-level
  # value could only ever be shadowed — the inert-key trap.
  @ladder_exclusive ~w(model sample_fps fps_band input_size)
  defp check_ladder_exclusions(acc, raw, name) do
    case Enum.filter(@ladder_exclusive, &Map.has_key?(raw, &1)) do
      [] ->
        acc

      keys ->
        Config.add_error(
          acc,
          "profile #{name}: model_ladder is mutually exclusive with " <>
            "#{Enum.join(keys, ", ")} — the resolved rung is the model, and " <>
            "sample_fps is derived from its budget (the ladder is the rate authority)"
        )
    end
  end

  # Resolution needs a floor rate, and only the tiers in `@ladder_floors`
  # have a measured one. Skipped for a tier `check_tier/3` already refused —
  # one unknown value, one error.
  defp check_ladder_tier(acc, raw, name) do
    case Map.get(raw, "tier") do
      nil ->
        Config.add_error(
          acc,
          "profile #{name}: model_ladder requires tier: — resolution divides rung " <>
            "budgets against the tier's floor rate; declare tier: 1"
        )

      tier when tier in @tiers ->
        Config.check(
          acc,
          ladder_floor(tier) != nil,
          "profile #{name}: model_ladder is not available at tier #{tier} yet — a " <>
            "tier-#{tier} ladder needs every rung bar-verified and a measured floor " <>
            "rate, and neither exists today; tier 1 is the ladder tier that ships"
        )

      _already_refused ->
        acc
    end
  end

  defp check_rungs(acc, list, raw, name) do
    backend = Map.get(raw, "backend", "ort")

    list
    |> Enum.with_index(1)
    |> Enum.reduce(acc, fn {rung, index}, acc ->
      check_rung(acc, rung, index, backend, raw, name)
    end)
  end

  defp check_rung(acc, rung, index, backend, raw, name) when is_map(rung) do
    where = "profile #{name} model_ladder rung #{index}"

    acc
    |> Config.warn_unknown(rung, @known_rung_keys, where)
    |> Config.warn_unknown(Map.get(rung, "model"), @known_model_keys, "#{where} model")
    |> check_rung_model(rung, index, backend, name)
    |> check_pos_int(rung, "input_size", name, "model_ladder rung #{index} input_size")
    |> check_rung_required(rung, "input_size", index, name)
    |> check_rung_budget(rung, index, name)
    |> check_rung_pack(rung, index, name)
    |> check_rung_model_profile(rung, index, backend, raw, name)
  end

  defp check_rung(acc, rung, index, _backend, _raw, name) do
    Config.add_error(
      acc,
      "profile #{name}: model_ladder rung #{index} must be a mapping, got #{inspect(rung)}"
    )
  end

  # Each rung is a model choice for THIS profile's backend, so beyond the
  # top-level `model:` shape rules it must actually carry the backend's
  # artifact key — a rung without one could never be resolved into anything
  # the engine loads.
  defp check_rung_model(acc, rung, index, backend, name) do
    case Map.get(rung, "model") do
      model when is_map(model) and model != %{} ->
        acc
        |> check_rung_model_leaves(model, index, name)
        |> check_rung_backend_key(model, index, backend, name)

      _absent_or_not_a_map ->
        Config.add_error(
          acc,
          "profile #{name}: model_ladder rung #{index} model must be a mapping of " <>
            "per-backend artifact paths"
        )
    end
  end

  defp check_rung_model_leaves(acc, model, index, name) do
    model
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reduce(acc, fn key, acc ->
      case Map.fetch!(model, key) do
        value when is_binary(value) and value != "" ->
          acc

        value ->
          Config.add_error(
            acc,
            "profile #{name}: model_ladder rung #{index} model.#{key} must be a path " <>
              "string, got #{inspect(value)}"
          )
      end
    end)
  end

  # Skipped for a backend outside the menu — `check_backend/3` already spoke,
  # and there is no artifact key to hold the rung against.
  defp check_rung_backend_key(acc, model, index, backend, name) when backend in @backends do
    Config.check(
      acc,
      is_binary(Map.get(model, artifact_key(backend))),
      "profile #{name}: model_ladder rung #{index} names no model.#{artifact_key(backend)} " <>
        "artifact for this profile's #{backend} backend — every rung must carry one"
    )
  end

  defp check_rung_backend_key(acc, _model, _index, _backend, _name), do: acc

  # `check_pos_int/5` says nothing about an absent key (top-level fields are
  # optional); a rung's `input_size` is not. Tested by value, not key
  # presence: a bare `input_size:` parses to nil, which check_pos_int also
  # reads as absent — key presence here would let it through undeclared.
  defp check_rung_required(acc, rung, key, index, name) do
    Config.check(
      acc,
      Map.get(rung, key) != nil,
      "profile #{name}: model_ladder rung #{index} must declare #{key}"
    )
  end

  defp check_rung_budget(acc, rung, index, name) do
    case Map.get(rung, "engine_budget") do
      budget when is_number(budget) and budget > 0 ->
        acc

      other ->
        Config.add_error(
          acc,
          "profile #{name}: model_ladder rung #{index} engine_budget must be a positive " <>
            "number of measured passes/s, got #{inspect(other)}"
        )
    end
  end

  defp check_rung_pack(acc, rung, index, name) do
    case Map.get(rung, "pack") do
      nil ->
        acc

      pack when is_binary(pack) and pack != "" ->
        acc

      other ->
        Config.add_error(
          acc,
          "profile #{name}: model_ladder rung #{index} pack must be a pack name string, " <>
            "got #{inspect(other)}"
        )
    end
  end

  # A rung's own family gets `check_model_profile/3`'s menu treatment and
  # `check_capabilities/5`'s backend rules. Only a rung that DECLARES a
  # family is checked here — one inheriting the profile-level
  # `model_profile:` was already checked by the top-level chain, and
  # re-running it per rung would report one mistake once per rung.
  defp check_rung_model_profile(acc, rung, index, backend, raw, name) do
    case Map.get(rung, "model_profile") do
      nil ->
        acc

      value when is_binary(value) and value != "" ->
        case family(value) do
          nil ->
            Config.add_error(
              acc,
              "profile #{name}: model_ladder rung #{index} unknown model_profile " <>
                "#{inspect(value)} (#{family_menu()})"
            )

          family when backend in @backends ->
            check_capabilities(acc, name, backend, Map.get(raw, "experimental") === true, family)

          _family_but_unknown_backend ->
            acc
        end

      other ->
        Config.add_error(
          acc,
          "profile #{name}: model_ladder rung #{index} model_profile must be a string, " <>
            "got #{inspect(other)}"
        )
    end
  end

  # Only over budgets that individually parsed — with any rung already
  # errored, an ordering verdict would be noise about a list the author is
  # about to rewrite.
  defp check_budget_order(acc, list, name) do
    budgets = Enum.map(list, &(is_map(&1) && Map.get(&1, "engine_budget")))

    if Enum.all?(budgets, &(is_number(&1) and &1 > 0)) do
      budgets
      |> Enum.with_index(1)
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.reduce(acc, fn [{prev, _i}, {budget, index}], acc ->
        Config.check(
          acc,
          budget > prev,
          "profile #{name}: model_ladder budgets must be strictly increasing down the " <>
            "list (rung #{index} budgets #{budget} after #{prev}) — order is most " <>
            "accurate first, and a later rung exists to buy more capacity"
        )
      end)
    else
      acc
    end
  end

  # `supported_cameras:` is the ladder's support CLAIM — the camera count the
  # file stands behind — and resolution enforces it as a bound: a fleet past
  # it is refused even when a rung's budget would cover it (`Cairn.Config`'s
  # resolve pass). So a ladder without one has nothing to enforce and nothing
  # for the Apache-complete invariant to hold against — required together. On
  # a single-model profile the key parses but nothing reads it, and an
  # operator who wrote it meant it to do something, so the inert case warns
  # rather than passing silently. A bare integer, not the design sketch's
  # {min, max} mapping: a minimum fleet size never grew semantics, so it was
  # dropped rather than enforced (Ben, 2026-08-15).
  defp check_supported_cameras(acc, raw, name) do
    # `!= nil`, not `has_key?`: a bare `model_ladder:` parses to nil, which
    # this whole module reads as "said nothing" (the `tracking:` rule) — a
    # key-presence test here would make the one check disagree with every
    # other reader of the key.
    ladder? = Map.get(raw, "model_ladder") != nil

    case Map.get(raw, "supported_cameras") do
      nil ->
        Config.check(
          acc,
          not ladder?,
          "profile #{name}: model_ladder requires supported_cameras — the claimed " <>
            "camera count is what resolution bounds and the Apache-complete " <>
            "invariant holds against"
        )

      max when is_integer(max) and max > 0 ->
        if ladder? do
          acc
        else
          Config.add_warning(
            acc,
            "profile #{name}: supported_cameras has no effect without model_ladder — " <>
              "nothing reads it on a single-model profile"
          )
        end

      other ->
        Config.add_error(
          acc,
          "profile #{name}: supported_cameras must be the maximum camera count this " <>
            "profile claims support for (a positive integer), got #{inspect(other)}"
        )
    end
  end

  # The Apache-complete invariant (D-L2, Ben 2026-08-14): the shipped
  # container is complete on its non-pack rungs alone. Packs raise accuracy
  # at a given fleet size; they never extend nominal support or become
  # load-bearing for any camera count — so the non-pack rungs by themselves
  # must cover the ladder's own declared max at the tier's floor rate, and a
  # ladder that leans on packs for any count is an authoring error. Pure
  # arithmetic over the file, so it runs at parse rather than waiting for a
  # group to use the profile; guarded on every input having parsed, since a
  # coverage verdict about a malformed ladder is noise.
  defp check_ladder_coverage(acc, raw, name) do
    with rungs when is_list(rungs) and rungs != [] <- Map.get(raw, "model_ladder"),
         true <- Enum.all?(rungs, &valid_rung_for_coverage?/1),
         max when is_integer(max) and max > 0 <- Map.get(raw, "supported_cameras"),
         %{floor_fps: floor_fps} <- ladder_floor(Map.get(raw, "tier")) do
      floor_rate = effective_rate(floor_fps)

      # `!= nil`, not `has_key?`: a bare `pack:` parses to nil, and every
      # other reader (`check_rung_pack/4`, resolution's skip split) reads
      # that as a non-pack rung — coverage must count it on the same side.
      case rungs
           |> Enum.reject(&(Map.get(&1, "pack") != nil))
           |> Enum.map(&Map.get(&1, "engine_budget")) do
        [] ->
          Config.add_error(
            acc,
            "profile #{name}: every model_ladder rung is a pack rung — the shipped " <>
              "container must cover the full supported_cameras range with no pack " <>
              "installed (Apache-complete invariant)"
          )

        budgets ->
          covered = trunc(Enum.max(budgets) / floor_rate)

          Config.check(
            acc,
            covered >= max,
            "profile #{name}: the non-pack rungs alone cover ~#{covered} cameras at " <>
              "tier #{Map.get(raw, "tier")}'s #{floor_fps} fps floor (largest non-pack " <>
              "budget #{Enum.max(budgets)} passes/s ÷ #{floor_rate}/s effective), but " <>
              "supported_cameras claims #{max} — packs may raise accuracy, never " <>
              "coverage (Apache-complete invariant); lower the claim or add a non-pack rung"
          )
      end
    else
      _malformed_elsewhere -> acc
    end
  end

  # nil-or-binary, never a key-presence test: a bare `pack:` (nil) is a
  # non-pack rung like everywhere else, and treating it as malformed here
  # would silently skip the coverage invariant for the whole ladder.
  defp valid_rung_for_coverage?(rung) do
    is_map(rung) and is_number(Map.get(rung, "engine_budget")) and
      Map.get(rung, "engine_budget") > 0 and
      (is_nil(Map.get(rung, "pack")) or is_binary(Map.get(rung, "pack")))
  end

  # "a, b or c" — enumerated from the table rather than hand-written so a value
  # added to one can't be forgotten in the message.
  defp natural_list(list) do
    case Enum.sort(list) do
      [single] -> single
      sorted -> "#{sorted |> Enum.drop(-1) |> Enum.join(", ")} or #{List.last(sorted)}"
    end
  end

  defp check_pos_int(acc, raw, key, name, label \\ nil) do
    case Map.get(raw, key) do
      nil ->
        acc

      value when is_integer(value) and value > 0 ->
        acc

      other ->
        Config.add_error(
          acc,
          "profile #{name}: #{label || key} must be a positive integer, got #{inspect(other)}"
        )
    end
  end

  defp check_fps_band(acc, raw, name) do
    case Map.get(raw, "fps_band") do
      nil ->
        acc

      [min, max] when is_number(min) and is_number(max) and min > 0 and min <= max ->
        acc

      other ->
        Config.add_error(
          acc,
          "profile #{name}: fps_band must be [min, max] with 0 < min <= max, got #{inspect(other)}"
        )
    end
  end

  # D-P4, the band-validates-never-emits rule: absent `sample_fps:` is not an
  # error at any `fps_band`, and mirrors clap's own `1..30` bound on the
  # plugin's `--sample-fps` (`plugins/cairn-detect`) so a value this side
  # accepts is one the process would too. A present-but-out-of-range integer
  # falls straight into the fallback clause below — 0 and 31 fail the guard
  # the same way a float or a string does — so one message covers all three
  # shapes of "not a legal sample_fps" rather than three near-duplicates.
  defp check_sample_fps(acc, raw, name) do
    case Map.get(raw, "sample_fps") do
      nil ->
        acc

      value when is_integer(value) and value >= 1 and value <= 30 ->
        check_sample_fps_band(acc, raw, name, value)

      other ->
        Config.add_error(
          acc,
          "profile #{name}: sample_fps must be an integer between 1 and 30, got #{inspect(other)}"
        )
    end
  end

  # Only fires against a `fps_band:` that itself parsed — a malformed band
  # already has its own error from `check_fps_band/3`, and re-reading it here
  # would either duplicate that message or, worse, misreport a band shape
  # this function was never meant to validate.
  defp check_sample_fps_band(acc, raw, name, value) do
    case Map.get(raw, "fps_band") do
      [min, max] when is_number(min) and is_number(max) and min > 0 and min <= max ->
        # Built as a string, not `inspect([min, max])`: small integers with a
        # named escape (8 is "\b", 12 is "\f", …) make `inspect/1` print the
        # pair as a charlist instead of a list — correct, but unreadable in an
        # error an operator has to act on.
        Config.check(
          acc,
          value >= min and value <= max,
          "profile #{name}: sample_fps #{value} contradicts fps_band [#{min}, #{max}] " <>
            "— a declared sample_fps must fall inside its own fps_band"
        )

      _absent_or_already_reported ->
        acc
    end
  end

  defp check_tracking(acc, raw, name) do
    tracking = Map.get(raw, "tracking")

    if is_nil(tracking) or is_map(tracking) do
      tracking = tracking || %{}
      acc = Enum.reduce(Map.keys(@stage_modules), acc, &check_stage_value(&2, tracking, &1, name))

      Enum.reduce(
        ~w(max_unseen_ms max_live_tracks stationary_after_ms),
        acc,
        &check_pos_int(&2, tracking, &1, name, "tracking.#{&1}")
      )
    else
      Config.add_error(acc, "profile #{name}: tracking must be a mapping")
    end
  end

  # `model:` is the one field `Cairn.Config` reads as a map rather than a
  # scalar (`Profile.artifact/1` does `Map.get(model, key)`) — an untyped
  # value here would raise inside `Config.load/1`, which has no rescue,
  # instead of surfacing through `add_error/2`. Sorted keys so error order is
  # stable across runs.
  defp check_model(acc, raw, name) do
    case Map.get(raw, "model") do
      nil ->
        acc

      model when is_map(model) ->
        model
        |> Map.keys()
        |> Enum.sort()
        |> Enum.reduce(acc, &check_model_value(&2, &1, Map.fetch!(model, &1), name))

      _other ->
        Config.add_error(
          acc,
          "profile #{name}: model must be a mapping of per-backend artifact paths"
        )
    end
  end

  defp check_model_value(acc, _key, value, _name) when is_binary(value) and value != "", do: acc

  defp check_model_value(acc, key, value, name) do
    Config.add_error(
      acc,
      "profile #{name}: model.#{key} must be a path string, got #{inspect(value)}"
    )
  end

  defp check_string(acc, raw, key, name) do
    case Map.get(raw, key) do
      nil ->
        acc

      value when is_binary(value) and value != "" ->
        acc

      other ->
        Config.add_error(acc, "profile #{name}: #{key} must be a string, got #{inspect(other)}")
    end
  end

  defp check_experimental(acc, raw, name) do
    case Map.get(raw, "experimental") do
      nil ->
        acc

      value when is_boolean(value) ->
        acc

      other ->
        Config.add_error(
          acc,
          "profile #{name}: experimental must be true or false, got #{inspect(other)}"
        )
    end
  end

  defp check_stage_value(acc, tracking, key, name) do
    case Map.get(tracking, key) do
      nil ->
        acc

      value when is_boolean(value) ->
        acc

      params when is_map(params) ->
        acc

      other ->
        Config.add_error(
          acc,
          "profile #{name}: tracking.#{key} must be true, false or a params mapping, " <>
            "got #{inspect(other)}"
        )
    end
  end
end
