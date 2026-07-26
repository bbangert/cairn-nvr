defmodule Cairn.Config do
  @moduledoc """
  Typed application configuration loaded from a YAML file.

  `load/1` parses and validates the file, returning `{:ok, config, warnings}`
  or `{:error, errors}`. Validation is strict on errors (bad values, missing
  required fields, UDP port exhaustion) and lenient on unknown keys, which
  only produce warnings.

  `CAIRN_DATA_DIR` (env) overrides `data_dir` from the file.
  """

  alias Cairn.Config.Camera
  alias Cairn.Config.PluginGroup

  @known_keys ~w(data_dir stall_seconds free_space_min_mb remux_clips udp events retention cameras
                 plugins integrations)
  @known_udp_keys ~w(base_port range)
  @known_events_keys ~w(pre_window_seconds post_window_seconds max_event_seconds)
  @known_retention_keys ~w(days per_label)
  @known_integrations_keys ~w(token)
  @name_regex ~r/\A[a-z0-9][a-z0-9_-]*\z/

  defstruct data_dir: "data",
            stall_seconds: 15,
            free_space_min_mb: 1024,
            remux_clips: true,
            udp_base_port: nil,
            udp_port_range: nil,
            pre_window_seconds: 5,
            post_window_seconds: 10,
            max_event_seconds: 300,
            retention_days: 14,
            retention_per_label: %{},
            cameras: [],
            plugin_groups: [],
            ha_token: nil

  @type t :: %__MODULE__{}

  @doc "Loads and validates the YAML config file at `path`."
  @spec load(Path.t()) :: {:ok, t(), [String.t()]} | {:error, [String.t()]}
  def load(path) do
    with {:ok, raw} <- read_file(path),
         {:ok, map} <- parse_yaml(raw) do
      from_map(map)
    end
  end

  @doc """
  Resolves the effective data dir without a running server: env override,
  then the YAML file at `path` (best effort), then the `"data"` default.
  """
  @spec resolve_data_dir(Path.t()) :: String.t()
  def resolve_data_dir(path) do
    case System.get_env("CAIRN_DATA_DIR") do
      nil -> data_dir_from_file(path)
      dir -> dir
    end
  end

  @doc "Default config path: `CAIRN_CONFIG` env or `config.yml` in cwd."
  @spec default_path() :: String.t()
  def default_path do
    System.get_env("CAIRN_CONFIG") ||
      Application.get_env(:cairn, :config_path, "config.yml")
  end

  defp data_dir_from_file(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, map} when is_map(map) <- YamlElixir.read_from_string(raw),
         dir when is_binary(dir) <- Map.get(map, "data_dir") do
      dir
    else
      _ -> "data"
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, raw} -> {:ok, raw}
      {:error, reason} -> {:error, ["cannot read config #{path}: #{inspect(reason)}"]}
    end
  end

  defp parse_yaml(raw) do
    case YamlElixir.read_from_string(raw) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _other} -> {:error, ["config must be a YAML mapping"]}
      {:error, err} -> {:error, ["YAML parse error: #{Exception.message(err)}"]}
    end
  end

  @doc false
  @spec from_map(map()) :: {:ok, t(), [String.t()]} | {:error, [String.t()]}
  def from_map(map) do
    acc = %{errors: [], warnings: []}
    acc = warn_unknown(acc, map, @known_keys, "config")
    acc = warn_unknown(acc, Map.get(map, "udp"), @known_udp_keys, "udp")
    acc = warn_unknown(acc, Map.get(map, "events"), @known_events_keys, "events")
    acc = warn_unknown(acc, Map.get(map, "retention"), @known_retention_keys, "retention")

    acc =
      warn_unknown(acc, Map.get(map, "integrations"), @known_integrations_keys, "integrations")

    {cameras, acc} = parse_cameras(Map.get(map, "cameras", []), acc)
    {plugin_groups, acc} = parse_plugins(Map.get(map, "plugins"), acc)

    config = %__MODULE__{
      data_dir: System.get_env("CAIRN_DATA_DIR") || Map.get(map, "data_dir", "data"),
      stall_seconds: Map.get(map, "stall_seconds", 15),
      free_space_min_mb: Map.get(map, "free_space_min_mb", 1024),
      remux_clips: Map.get(map, "remux_clips", true),
      udp_base_port: get_in(map, ["udp", "base_port"]),
      udp_port_range: get_in(map, ["udp", "range"]),
      pre_window_seconds: get_in(map, ["events", "pre_window_seconds"]) || 5,
      post_window_seconds: get_in(map, ["events", "post_window_seconds"]) || 10,
      max_event_seconds: get_in(map, ["events", "max_event_seconds"]) || 300,
      retention_days: get_in(map, ["retention", "days"]) || 14,
      retention_per_label: get_in(map, ["retention", "per_label"]) || %{},
      cameras: cameras,
      plugin_groups: plugin_groups,
      ha_token: get_in(map, ["integrations", "token"])
    }

    {config, acc} = resolve_plugins(config, acc, declared_plugin_names(map))
    acc = validate(config, acc)

    case acc.errors do
      [] -> {:ok, config, Enum.reverse(acc.warnings)}
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  @doc "Effective pre/post/max windows for a camera (camera override or global)."
  @spec windows(t(), Camera.t()) :: %{pre: pos_integer(), post: pos_integer(), max: pos_integer()}
  def windows(%__MODULE__{} = config, %Camera{} = cam) do
    %{
      pre: cam.pre_window_seconds || config.pre_window_seconds,
      post: cam.post_window_seconds || config.post_window_seconds,
      max: cam.max_event_seconds || config.max_event_seconds
    }
  end

  @doc "Effective retention days for a camera and label."
  @spec retention_days(t(), Camera.t(), String.t()) :: pos_integer()
  def retention_days(%__MODULE__{} = config, %Camera{} = cam, label) do
    Map.get(cam.retention_per_label, label) ||
      cam.retention_days ||
      Map.get(config.retention_per_label, label) ||
      config.retention_days
  end

  # -- camera parsing ---------------------------------------------------------

  defp parse_cameras(cameras, acc) when is_list(cameras) do
    {cams, acc} =
      cameras
      |> Enum.with_index()
      |> Enum.reduce({[], acc}, fn {raw, idx}, {cams, acc} ->
        {cam, acc} = Camera.parse(raw, idx, acc)
        {[cam | cams], acc}
      end)

    {cams |> Enum.reject(&is_nil/1) |> Enum.reverse(), acc}
  end

  defp parse_cameras(_other, acc) do
    {[], add_error(acc, "cameras must be a list")}
  end

  # -- plugin group parsing ---------------------------------------------------

  defp parse_plugins(nil, acc), do: {[], acc}

  defp parse_plugins(plugins, acc) when is_map(plugins) do
    {groups, acc} =
      plugins
      |> Enum.sort_by(fn {name, _raw} -> name end)
      |> Enum.reduce({[], acc}, fn
        {name, raw}, {groups, acc} when is_binary(name) ->
          {group, acc} = PluginGroup.parse(raw, name, acc)
          {[group | groups], acc}

        {name, _raw}, {groups, acc} ->
          {groups, add_error(acc, "plugin #{inspect(name)}: name must be a string")}
      end)

    {groups |> Enum.reject(&is_nil/1) |> Enum.reverse(), acc}
  end

  defp parse_plugins(_other, acc) do
    {[], add_error(acc, "plugins must be a mapping of name to plugin")}
  end

  # Cameras leave `Camera.parse/3` with `{:pending, name}` for a single-token
  # `plugin:` string; only here is the full `plugins:` map known, so a name
  # becomes a `{:group, name}` reference or (typo) a config error.
  defp resolve_plugins(config, acc, declared) do
    names = MapSet.new(config.plugin_groups, & &1.name)

    {cameras, acc} =
      Enum.map_reduce(config.cameras, acc, &resolve_camera_plugin(&1, &2, names, declared))

    config = %{config | cameras: cameras}

    {%{config | plugin_groups: resolve_members(config)}, acc}
  end

  # Names present in the raw plugins: map, including entries whose own parse
  # failed — a camera referencing those must not pile a misleading "unknown
  # plugin" error on top of the group's error.
  defp declared_plugin_names(map) do
    case Map.get(map, "plugins") do
      plugins when is_map(plugins) -> Enum.map(Map.keys(plugins), &to_string/1)
      _other -> []
    end
  end

  defp resolve_camera_plugin(%Camera{plugin: {:pending, name}} = cam, acc, names, declared) do
    cond do
      MapSet.member?(names, name) ->
        {%{cam | plugin: {:group, name}}, acc}

      name in declared ->
        {%{cam | plugin: nil}, acc}

      true ->
        {%{cam | plugin: nil},
         add_error(
           acc,
           "camera #{cam.id}: unknown plugin #{inspect(name)} — define it under plugins: " <>
             "or write an inline command as a list"
         )}
    end
  end

  defp resolve_camera_plugin(cam, acc, _names, _declared), do: {cam, acc}

  defp resolve_members(%__MODULE__{udp_base_port: base} = config) when is_integer(base) do
    Enum.map(config.plugin_groups, &%{&1 | members: members_for(config, &1.name)})
  end

  defp resolve_members(config), do: config.plugin_groups

  defp members_for(config, name) do
    config.cameras
    |> Enum.with_index()
    |> Enum.filter(fn {cam, _index} -> cam.plugin == {:group, name} end)
    |> Enum.map(fn {cam, index} ->
      {udp_port, _rtp_port} = Cairn.UDPPorts.ports_for(config, index)
      %{id: cam.id, udp_port: udp_port, min_score: cam.min_score}
    end)
  end

  # -- validation -------------------------------------------------------------

  defp validate(config, acc) do
    acc
    |> validate_ids(config)
    |> validate_plugins(config)
    |> validate_windows(config)
    |> validate_udp(config)
    |> validate_numbers(config)
    |> validate_remux(config)
    |> validate_ha_token(config)
  end

  defp validate_ha_token(acc, %{ha_token: nil}), do: acc

  defp validate_ha_token(acc, %{ha_token: token}) when is_binary(token) and token != "",
    do: acc

  defp validate_ha_token(acc, _config),
    do: add_error(acc, "integrations.token must be a non-empty string")

  defp validate_remux(acc, %{remux_clips: v}) when is_boolean(v), do: acc

  defp validate_remux(acc, _config),
    do: add_error(acc, "remux_clips must be true or false")

  defp validate_ids(acc, config) do
    ids = Enum.map(config.cameras, & &1.id)
    dups = Enum.uniq(ids -- Enum.uniq(ids))

    Enum.reduce(dups, acc, &add_error(&2, "duplicate camera id: #{&1}"))
  end

  # Group names and camera ids share the `plugin-{name}.log` namespace, so
  # they must not collide.
  defp validate_plugins(acc, config) do
    camera_ids = MapSet.new(config.cameras, & &1.id)
    # Names are keys of the plugins: mapping, so they are unique by
    # construction (YAML duplicate keys collapse at parse time).
    names = Enum.map(config.plugin_groups, & &1.name)

    Enum.reduce(names, acc, fn name, acc ->
      acc
      |> check(name =~ @name_regex, "plugin #{name}: name must be lowercase [a-z0-9_-]")
      |> check(
        not MapSet.member?(camera_ids, name),
        "plugin #{name}: name collides with a camera id"
      )
    end)
  end

  defp validate_windows(acc, config) do
    cams = [
      {nil, config}
      | Enum.map(config.cameras, &{&1.id, Map.merge(config, windows_map(config, &1))})
    ]

    Enum.reduce(cams, acc, fn {id, c}, acc ->
      prefix = if id, do: "camera #{id}: ", else: ""

      acc
      |> check(int?(c.pre_window_seconds, 0, 600), "#{prefix}pre_window_seconds must be 0..600")
      |> check(int?(c.post_window_seconds, 1, 600), "#{prefix}post_window_seconds must be 1..600")
      |> check(
        int?(c.max_event_seconds, 5, 86_400),
        "#{prefix}max_event_seconds must be 5..86400"
      )
      |> check(
        c.max_event_seconds >= c.post_window_seconds,
        "#{prefix}max_event_seconds must be >= post_window_seconds"
      )
    end)
  end

  defp windows_map(config, cam) do
    w = windows(config, cam)

    %{
      pre_window_seconds: w.pre,
      post_window_seconds: w.post,
      max_event_seconds: w.max
    }
  end

  defp validate_udp(acc, %{udp_base_port: base, udp_port_range: range} = config) do
    needed = Cairn.UDPPorts.ports_per_camera() * length(config.cameras)

    cond do
      is_nil(base) or is_nil(range) ->
        add_error(acc, "udp.base_port and udp.range are required")

      not int?(base, 1024, 65_535) ->
        add_error(acc, "udp.base_port must be 1024..65535")

      not int?(range, 2, 65_536 - base) ->
        add_error(acc, "udp.range must be >= 2 and base_port + range must fit below 65536")

      needed > range ->
        add_error(
          acc,
          "udp range exhausted: #{length(config.cameras)} cameras need #{needed} ports, " <>
            "range provides #{range}"
        )

      true ->
        acc
    end
  end

  defp validate_numbers(acc, config) do
    acc
    |> check(int?(config.stall_seconds, 1, 3600), "stall_seconds must be 1..3600")
    |> check(int?(config.free_space_min_mb, 0, 10_000_000), "free_space_min_mb must be >= 0")
    |> check(int?(config.retention_days, 1, 10_000), "retention.days must be >= 1")
    |> check(is_binary(config.data_dir), "data_dir must be a string")
  end

  defp int?(v, min, max), do: is_integer(v) and v >= min and v <= max

  # -- accumulator helpers ----------------------------------------------------

  @doc false
  def add_error(acc, msg), do: %{acc | errors: [msg | acc.errors]}

  @doc false
  def add_warning(acc, msg), do: %{acc | warnings: [msg | acc.warnings]}

  @doc false
  def check(acc, true, _msg), do: acc
  def check(acc, false, msg), do: add_error(acc, msg)

  @doc false
  def warn_unknown(acc, map, known, where) when is_map(map) do
    map
    |> Map.keys()
    |> Enum.reject(&(&1 in known))
    |> Enum.reduce(acc, &add_warning(&2, "unknown key #{inspect(&1)} in #{where}"))
  end

  def warn_unknown(acc, _not_map, _known, _where), do: acc
end
