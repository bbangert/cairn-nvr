defmodule Cairn.Config.Profile do
  @moduledoc """
  A hardware profile: one YAML file naming choices from menus the code
  exposes, attached to a plugin group by name (`profile: <name>` on an entry
  of `plugins:`).

  A profile is **data composing curated code**, not free knob tuning: every
  field names something that already exists — a Rust model family, a
  backend, a tracker stage. What config load enforces *today* is the shape
  of that naming: unknown keys, unknown backends, malformed bands and
  illegal stage compositions are rejected here; artifact-exists checks,
  the experimental acknowledgement for stubbed backends, and catalog
  validation of `model_profile`/`decoder`/`labels` land with the argv
  expansion (plan phase 5) and the capability table (phase 7).
  Profiles are files, never inline config: shipped ones live
  in `priv/profiles/*.yml`, operator ones in the directories the top-level
  `profile_dirs:` key lists, and an operator file wins a name collision with
  a shipped one (with a warning saying so).

  ## Schema

  ```yaml
  # priv/profiles/generic-ort.yml
  name: generic-ort          # optional; must match the filename when present
  experimental: false        # will gate stubbed backends at group start (phase 5)
  backend: ort               # ort | rknn | qnn — only ort executes today
  model:                     # per-backend artifact paths
    onnx: models/yolox_nano.onnx
  model_profile: yolox       # Rust catalog family name
  input_size: 416
  decoder: auto
  labels: models/coco.names
  fps_band: [4, 8]           # declared, not measured (D-P5)
  tracking:                  # stage presence + params, plus band-tuned bounds
    bbd: true                # true = listed with defaults; a map = params
    oru: { }                 # equivalent to true
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

  Parsed on `Cairn.Config`'s `add_error/2`/`add_warning/2` contract like
  its `Camera`/`PluginGroup` siblings.
  """

  alias Cairn.Config
  alias Cairn.Tracker.Stage

  @known_keys ~w(name experimental backend model model_profile input_size decoder labels
                 fps_band tracking)
  @known_tracking_keys ~w(bbd oru twin_mint max_unseen_ms max_live_tracks stationary_after_ms)
  @backends ~w(ort rknn qnn)
  @known_model_keys ~w(onnx rknn)
  @stage_modules %{
    "bbd" => {:bbd, Stage.Bbd},
    "oru" => {:oru, Stage.Oru},
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
            # The stage presence map (atom key → params map), nil when the
            # file had no `tracking:` block at all — absence speaks (see the
            # moduledoc) — plus the three band-tuned tracker bounds (nil
            # where the file set none).
            stages: nil,
            max_unseen_ms: nil,
            max_live_tracks: nil,
            stationary_after_ms: nil

  @type t :: %__MODULE__{}

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
      |> check_tracking(raw, name)

    if length(acc.errors) > errors_before do
      {nil, acc}
    else
      tracking = Map.get(raw, "tracking")

      profile = %__MODULE__{
        name: name,
        experimental: Map.get(raw, "experimental") === true,
        backend: Map.get(raw, "backend", "ort"),
        model: Map.get(raw, "model") || %{},
        model_profile: Map.get(raw, "model_profile"),
        input_size: Map.get(raw, "input_size"),
        decoder: Map.get(raw, "decoder"),
        labels: Map.get(raw, "labels"),
        fps_band: Map.get(raw, "fps_band"),
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
  # keys: a stage reads its own vocabulary off them, and converting
  # operator-authored keys to atoms would be manufacturing atoms from input.
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
      per_object: stage_entry(profile, :oru)
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
          "profile #{name}: unknown backend #{inspect(other)} (ort, rknn or qnn)"
        )
    end
  end

  defp check_pos_int(acc, raw, key, name) do
    case Map.get(raw, key) do
      nil ->
        acc

      value when is_integer(value) and value > 0 ->
        acc

      other ->
        Config.add_error(
          acc,
          "profile #{name}: #{key} must be a positive integer, got #{inspect(other)}"
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

  defp check_tracking(acc, raw, name) do
    tracking = Map.get(raw, "tracking")

    if is_nil(tracking) or is_map(tracking) do
      tracking = tracking || %{}
      acc = Enum.reduce(Map.keys(@stage_modules), acc, &check_stage_value(&2, tracking, &1, name))

      Enum.reduce(
        ~w(max_unseen_ms max_live_tracks stationary_after_ms),
        acc,
        &check_pos_int(&2, tracking, &1, name)
      )
    else
      Config.add_error(acc, "profile #{name}: tracking must be a mapping")
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
