defmodule Cairn.Config.Profile do
  @moduledoc """
  A hardware profile: one YAML file naming choices from menus the code
  exposes, attached to a plugin group by name (`profile: <name>` on an entry
  of `plugins:`).

  A profile is **data composing curated code**, not free knob tuning: every
  field names something that already exists — a Rust model family, a
  backend, a tracker stage. What config load enforces *today* is the shape
  of that naming: unknown keys, unknown backends, malformed bands, illegal
  stage compositions, and the type of every field the model half reads
  (`model:` a mapping of path strings, `model_profile:`/`decoder:`/`labels:`
  strings, `experimental:` a boolean) are rejected here, and `Cairn.Config`
  rejects a profiled group whose artifact is missing or whose backend is
  stubbed (see "Rust argv" below); catalog validation of
  `model_profile`/`decoder`/`labels` against the plugin's own menus lands
  with the capability table (plan phase 7).
  Profiles are files, never inline config: shipped ones live
  in `priv/profiles/*.yml`, operator ones in the directories the top-level
  `profile_dirs:` key lists, and an operator file wins a name collision with
  a shipped one (with a warning saying so).

  ## Schema

  ```yaml
  # priv/profiles/generic-ort.yml
  name: generic-ort          # optional; must match the filename when present
  experimental: false        # true before any group may run a stubbed backend
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

  ## Rust argv

  The model half of the file is materialised into the group's `command` at
  config load (`Cairn.Config`), one flag per field the profile actually
  sets: `--model` (the `model:` entry for this profile's own backend),
  `--model-profile`, `--input-size`, `--decoder`, `--labels`. An unset field
  emits no flag, leaving the plugin's own default or its sniffing in force.
  Because the profile is the **single source** of those five (D-P4), a
  profiled group whose `command:` already names one fails the load;
  `--motion-json` and `--track-floor-json` are not on that list and stay
  operator-owned (D-P6).

  Two things `Cairn.Config` refuses at load rather than at group start,
  which is where an operator reads diagnostics: a `model:` artifact that is
  not on disk, and a group running a backend other than `ort` — stubbed
  until the Rust backend trait lands (D-P10) — unless the profile declares
  `experimental: true` *and* the group sets `allow_experimental: true`.

  Parsed on `Cairn.Config`'s `add_error/2`/`add_warning/2` contract like
  its `Camera`/`PluginGroup` siblings.
  """

  alias Cairn.Config
  alias Cairn.Tracker.Stage

  @known_keys ~w(name experimental backend model model_profile input_size decoder labels
                 fps_band tracking)
  @known_tracking_keys ~w(bbd oru twin_mint max_unseen_ms max_live_tracks stationary_after_ms)
  # Each backend paired with the `model:` key naming its compiled artifact:
  # backends consume different formats (prior-art §1), so a profile ships one
  # artifact per backend and the profile's own backend picks which path
  # becomes `--model`. Derived rather than repeated so a backend cannot be
  # added to one list and forgotten in the other.
  @backend_artifacts %{"ort" => "onnx", "rknn" => "rknn", "qnn" => "qnn"}
  @backends Map.keys(@backend_artifacts)
  @known_model_keys Map.values(@backend_artifacts)
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
      |> check_model(raw, name)
      |> check_string(raw, "model_profile", name)
      |> check_string(raw, "decoder", name)
      |> check_string(raw, "labels", name)
      |> check_experimental(raw, name)

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
          "profile #{name}: unknown backend #{inspect(other)} (#{natural_list(@backends)})"
        )
    end
  end

  # "a, b or c" — enumerated from `@backends` rather than hand-written so a
  # backend added to `@backend_artifacts` can't be forgotten in the message.
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
