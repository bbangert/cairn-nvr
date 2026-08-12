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
  ```

  The `tracking:` block expresses **presence, not order** (D-P2): a stage
  key present means listed, absent means not, and the tracker's fixed
  insertion points decide where each runs. The block itself is the stage
  list — present-but-empty means "run nothing", while omitting the block
  entirely means the profile says nothing about tracking and the camera's
  boolean flags stand. The translated lists are
  validated against every stage's declared constraints at load
  (`Cairn.Tracker.Stage.validate_lists/1`) — an illegal composition fails
  the config load, since the tracker has no error channel.

  ## The model half, twice

  The same six fields reach two detection paths. `model_argv/1` renders them
  as the plugin's argv, materialised into the group's `command` at config load
  (`Cairn.Config`): `--model` (the `model:` entry for this profile's own
  backend), `--model-profile`, `--input-size`, `--decoder`, `--labels`,
  `--sample-fps`. `native_config/1` renders the same fields as the in-VM
  engine's init config for a membrane camera. Both walk one table (`model/1`),
  which is what stops a profile field from reaching one path and not the other.

  An unset field emits no flag, leaving the plugin's own default or its
  sniffing in force. `--sample-fps` is the one flag `fps_band:` never fills
  in for: the band only validates a declared `sample_fps:` (D-P4) — it is
  never the source of the flag, so a profile with a band and no `sample_fps:`
  still emits nothing. Because the profile is the **single source** of those
  six (D-P4), a profiled group whose `command:` already names one fails the
  load; `--motion-json` and `--track-floor-json` are not on that list and
  stay operator-owned (D-P6).

  Three things `Cairn.Config` refuses at load rather than at group start,
  which is where an operator reads diagnostics: a `model:` artifact that is
  not on disk, a `labels:` file that is not on disk, and a group running a
  backend other than `ort` — experimental until proven in soak, whether the
  plugin executes it (qnn) or stubs it (rknn) (D-P10) — unless the profile
  declares `experimental: true` *and* the group sets
  `allow_experimental: true`. The two file paths are checked only for a
  profile some group actually runs, so a board profile for hardware this node
  does not have costs it nothing.

  Parsed on `Cairn.Config`'s `add_error/2`/`add_warning/2` contract like
  its `Camera`/`PluginGroup` siblings.
  """

  alias Cairn.Config
  alias Cairn.Tracker.Stage

  @known_keys ~w(name experimental backend model model_profile input_size decoder labels
                 fps_band sample_fps tracking)
  @known_tracking_keys ~w(bbd oru ocr twin_mint max_unseen_ms max_live_tracks stationary_after_ms)
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

  defstruct name: nil,
            experimental: false,
            backend: "ort",
            model: %{},
            model_profile: nil,
            input_size: nil,
            decoder: nil,
            labels: nil,
            fps_band: nil,
            sample_fps: nil,
            # The stage presence map (atom key → params map), nil when the
            # file had no `tracking:` block at all — absence speaks (see the
            # moduledoc) — plus the three band-tuned tracker bounds (nil
            # where the file set none).
            stages: nil,
            max_unseen_ms: nil,
            max_live_tracks: nil,
            stationary_after_ms: nil

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

    if length(acc.errors) > errors_before do
      {nil, acc}
    else
      tracking = Map.get(raw, "tracking")

      profile = %__MODULE__{
        name: name,
        experimental: Map.get(raw, "experimental") || false,
        backend: Map.get(raw, "backend", "ort"),
        model: Map.get(raw, "model") || %{},
        model_profile: Map.get(raw, "model_profile"),
        input_size: Map.get(raw, "input_size"),
        decoder: Map.get(raw, "decoder"),
        labels: Map.get(raw, "labels"),
        fps_band: Map.get(raw, "fps_band"),
        sample_fps: Map.get(raw, "sample_fps"),
        stages: stages(tracking),
        max_unseen_ms: tracking && Map.get(tracking, "max_unseen_ms"),
        max_live_tracks: tracking && Map.get(tracking, "max_live_tracks"),
        stationary_after_ms: tracking && Map.get(tracking, "stationary_after_ms")
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
