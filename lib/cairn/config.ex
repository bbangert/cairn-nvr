defmodule Cairn.Config do
  @moduledoc """
  Typed application configuration loaded from a YAML file.

  `load/1` parses and validates the file, returning `{:ok, config, warnings}`
  or `{:error, errors}`. Validation is strict on errors (bad values, missing
  required fields, UDP port exhaustion) and lenient on unknown keys, which
  only produce warnings. One deliberate exception: an unknown key *inside* a
  `track:` / `record:` tier rule is an error, because a filter this codebase
  does not implement yet must not look applied (`Cairn.Config.Camera`).

  `CAIRN_DATA_DIR` (env) overrides `data_dir` from the file.
  """

  alias Cairn.Config.Camera
  alias Cairn.Config.PluginGroup

  @known_keys ~w(data_dir stall_seconds free_space_min_mb remux_clips udp events retention cameras
                 plugins integrations tracking)
  @known_udp_keys ~w(base_port range)
  @known_events_keys ~w(pre_window_seconds post_window_seconds max_event_seconds)
  @known_retention_keys ~w(days per_label tracks_days)
  @known_integrations_keys ~w(token)
  @known_tracking_keys ~w(max_unseen_ms max_live_tracks stationary_after_ms bbd oru)
  @name_regex ~r/\A[a-z0-9][a-z0-9_-]*\z/

  # How long a track survives without being seen, in *media* time. Long
  # enough to ride out an occlusion, short enough that a parked identity does
  # not get handed to whatever next overlaps it. The tracker makes one gated
  # exception to that second half: a track it has judged stationary gets a
  # bound `@stationary_unseen_factor` times this one, and pays for the extra
  # patience by refusing to re-match below `@stationary_match_iou` for as long
  # as it is over this bound — so a parked identity still goes to the object
  # that was parked there and to nothing else. Both constants live in
  # `Cairn.Tracker`; they are a pair, and neither is config.
  @default_max_unseen_ms 3_000
  # How many tracks one camera may hold live at once. The tracker lives in that
  # camera's own `Cairn.CameraTracker` and a plugin picks its own track ids, so
  # this is what stops one camera's plugin from growing that process without
  # bound — the per-camera split keeps the memory off its neighbours, and this
  # keeps it off the node. Large
  # enough for a crowded scene at 64 objects per frame; small enough that a
  # hostile plugin cannot mint its way out of memory.
  @default_max_live_tracks 128
  # How long an object must hold still, in *media* time, before it counts as
  # stationary. Long enough that someone standing at a door or a car waiting
  # at a gate is not called parked; short enough that a package left on the
  # step is reported while the event that dropped it is still open.
  #
  # This is the entry half only. Leaving the flag is sustained too, over
  # `Cairn.Tracker`'s `@stationary_exit_ms` — a fixed window, not derived from
  # this one and not config either, for the reason given there: it is sized
  # against the excursions `@stationary_velocity_floor` cannot absorb, which is not
  # something a view of the camera tells an operator anything about. Raising
  # this number makes the system slower to call things parked; it does not make
  # it quicker to notice them leaving.
  @default_stationary_after_ms 10_000
  # Whether association may admit a pair on `Cairn.Tracker.Bbd`'s centre
  # distance as well as on IoU. Off by default: it widens what a track will
  # answer to, and widening admission is how identities get handed to the wrong
  # object, so it is opt-in until soak measurement says otherwise.
  #
  # Global only, with none of the per-camera form the three bounds above have.
  # Those are scene descriptions an operator sets per camera — how long an
  # object may vanish, how crowded the frame is, how long "parked" takes here.
  # This is a rollout switch on the matcher itself, and a fleet where half the
  # cameras associate one way and half the other is not a thing an operator can
  # reason about or a soak can read.
  @default_bbd false
  # Whether a track's motion filter is rebuilt across an unmatched gap, from
  # the two real boxes that bound it, instead of being corrected through it
  # (`Cairn.Tracker`'s "Rebuilding a filter across a gap"). Off by default: it
  # replaces a velocity history the filter measured with an interpolation
  # between two sightings, which is the better reading only for as long as the
  # gap is one the pre-gap heading really has nothing to say about, so it is
  # opt-in until soak measurement says otherwise.
  #
  # Global only, for the reason `@default_bbd` is: this is a rollout switch on
  # the motion filter itself rather than a description of a scene, and a fleet
  # where half the cameras rebuild and half coast is not a thing an operator can
  # reason about or a soak can read.
  @default_oru false
  # How long track rows outlive the clips they describe. Deliberately far
  # longer than `retention_days`: the track log is the instrument for tuning
  # the filters, and a year of "what did the system see and not record?" is the
  # whole point of keeping it. It costs almost nothing — a track row is
  # hundreds of bytes against megabytes for a clip — so the two clocks are not
  # trading off against each other.
  @default_retention_tracks_days 365

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
            retention_tracks_days: @default_retention_tracks_days,
            max_unseen_ms: @default_max_unseen_ms,
            max_live_tracks: @default_max_live_tracks,
            stationary_after_ms: @default_stationary_after_ms,
            bbd: @default_bbd,
            oru: @default_oru,
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

    acc = warn_unknown(acc, Map.get(map, "tracking"), @known_tracking_keys, "tracking")

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
      retention_tracks_days: configured_retention_tracks_days(map),
      max_unseen_ms: configured_max_unseen_ms(map),
      max_live_tracks: configured_max_live_tracks(map),
      stationary_after_ms: configured_stationary_after_ms(map),
      bbd: configured_bbd(map),
      oru: configured_oru(map),
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

  defp configured_max_unseen_ms(map),
    do: get_in(map, ["tracking", "max_unseen_ms"]) || @default_max_unseen_ms

  defp configured_max_live_tracks(map),
    do: get_in(map, ["tracking", "max_live_tracks"]) || @default_max_live_tracks

  defp configured_stationary_after_ms(map),
    do: get_in(map, ["tracking", "stationary_after_ms"]) || @default_stationary_after_ms

  # Not `||` like its three neighbours: this key is a boolean, so an explicit
  # `false` has to survive being read whatever the default is, and only a
  # literal `true` may turn the matcher's second admission on — a truthy
  # non-boolean in the YAML is a typo, not an opt-in.
  defp configured_bbd(map) do
    case get_in(map, ["tracking", "bbd"]) do
      nil -> @default_bbd
      value -> value === true
    end
  end

  # Not `||`, on the same rule as `configured_bbd/1`: a boolean key has to read
  # an explicit `false` as a value rather than as an absence, and only a literal
  # `true` may rebuild anything — a truthy non-boolean in the YAML is a typo,
  # not an opt-in.
  defp configured_oru(map) do
    case get_in(map, ["tracking", "oru"]) do
      nil -> @default_oru
      value -> value === true
    end
  end

  # Global only: one clock for the whole track log, with none of the
  # per-camera or per-label forms `retention.days` has. Those exist to buy disk
  # back on clips. Splitting the audit record by label instead would make "what
  # did the system see and not record?" answerable only for the labels someone
  # already thought to keep, which is the question backwards.
  defp configured_retention_tracks_days(map),
    do: get_in(map, ["retention", "tracks_days"]) || @default_retention_tracks_days

  @doc """
  Everything the detection pipeline needs for a camera in one map: the event
  windows, the tracking settings, and the two host-side threshold tiers.

  The plugin ports resolve it off the per-frame path — at init and again on
  each `refresh/3` — and hand the result to `Cairn.CameraTracker` with
  every observation, so no camera tracker calls the config server per
  frame. `Cairn.PluginPort` and `Cairn.PluginGroupPort` both take their whole
  policy from this function and forward it unmodified, so every key added
  here reaches `Cairn.CameraTracker` through that same plumbing — and reaches
  a *running* camera only through those two refreshes.

  `:track` and `:record` are the camera's parsed tiers verbatim, `nil` when
  the block is absent. Resolve a label against one with `tier_threshold/3`
  rather than reading the map directly — `nil` and an unlisted label mean
  opposite things.
  """
  @spec policy(t(), Camera.t()) :: %{
          pre: pos_integer(),
          post: pos_integer(),
          max: pos_integer(),
          max_unseen_ms: pos_integer(),
          max_live_tracks: pos_integer(),
          stationary_after_ms: pos_integer(),
          bbd: boolean(),
          oru: boolean(),
          track: Camera.tier() | nil,
          record: Camera.tier() | nil
        }
  def policy(%__MODULE__{} = config, %Camera{} = cam) do
    config
    |> windows(cam)
    |> Map.put(:max_unseen_ms, max_unseen_ms(config, cam))
    |> Map.put(:max_live_tracks, max_live_tracks(config, cam))
    |> Map.put(:stationary_after_ms, stationary_after_ms(config, cam))
    # Straight off the config and not through a `cam` reader: there is no
    # per-camera form of this one (see `@default_bbd`).
    |> Map.put(:bbd, config.bbd)
    # And no per-camera form of this one either (see `@default_oru`).
    |> Map.put(:oru, config.oru)
    |> Map.put(:track, cam.track)
    |> Map.put(:record, cam.record)
  end

  @doc """
  The score `label` must reach to qualify for one tier, or `:excluded`.

  `rules` is a camera's parsed `track` or `record` tier (or `nil`), and
  `min_score` its wire-floor map — the `min_score` field, which always carries
  a `"default"` key.

    * tier absent (`nil`) — today's behaviour, where everything the plugin
      emits qualifies, so the answer is the label's own wire floor.
    * tier present — the label's own rule, else the tier's `"default"` rule,
      else `:excluded`. A present tier lists what it wants; an unlisted label
      with no `default:` is out of that tier, which is the whole point of
      having one.

  A returned number is a floor to compare a detection's score against. Given a
  camera's *configured* `min_score` it never comes back below that label's
  wire floor: a config where a tier resolves under `min_score` is rejected at
  load time, because the plugin never emits that band and the rule could only
  ever fire zero times. A runtime override (`Cairn.CameraControl`'s
  `min_score`) goes through no such validation and can sit above a tier —
  `Cairn.CameraTracker` resolves the clash by demanding both, so an
  override raises the bar without ever lowering a tier's.

  Between the two tiers, validation leaves one invariant worth relying on: for
  a given label the `record` answer is never a number below the `track`
  answer. Either it is higher, or `record` returned `:excluded` because a
  present `record:` block left the label out — the rows-without-video case.
  """
  @spec tier_threshold(Camera.tier() | nil, String.t(), %{optional(String.t()) => float()}) ::
          float() | :excluded
  def tier_threshold(nil, label, min_score), do: wire_floor(min_score, label)

  def tier_threshold(rules, label, _min_score) when is_map(rules) do
    case Map.get(rules, label) || Map.get(rules, "default") do
      %{min_score: score} -> score
      nil -> :excluded
    end
  end

  # Both `Camera.parse/3` and the struct's own default guarantee a "default"
  # key, so this resolves to a number for any camera that came from either.
  defp wire_floor(min_score, label),
    do: Map.get(min_score, label) || Map.get(min_score, "default")

  @doc "Effective track expiry (media milliseconds) for a camera."
  @spec max_unseen_ms(t(), Camera.t()) :: pos_integer()
  def max_unseen_ms(%__MODULE__{} = config, %Camera{} = cam),
    do: cam.max_unseen_ms || config.max_unseen_ms

  @doc "Track expiry used when no config is available (media milliseconds)."
  @spec default_max_unseen_ms() :: pos_integer()
  def default_max_unseen_ms, do: @default_max_unseen_ms

  @doc "Effective live-track cap for a camera."
  @spec max_live_tracks(t(), Camera.t()) :: pos_integer()
  def max_live_tracks(%__MODULE__{} = config, %Camera{} = cam),
    do: cam.max_live_tracks || config.max_live_tracks

  @doc "Live-track cap used when no config is available."
  @spec default_max_live_tracks() :: pos_integer()
  def default_max_live_tracks, do: @default_max_live_tracks

  @doc "Effective stillness threshold (media milliseconds) for a camera."
  @spec stationary_after_ms(t(), Camera.t()) :: pos_integer()
  def stationary_after_ms(%__MODULE__{} = config, %Camera{} = cam),
    do: cam.stationary_after_ms || config.stationary_after_ms

  @doc "Stillness threshold used when no config is available (media milliseconds)."
  @spec default_stationary_after_ms() :: pos_integer()
  def default_stationary_after_ms, do: @default_stationary_after_ms

  @doc "Whether BBD admission is on when no config is available."
  @spec default_bbd() :: boolean()
  def default_bbd, do: @default_bbd

  @doc "Whether gap replay is on when no config is available."
  @spec default_oru() :: boolean()
  def default_oru, do: @default_oru

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
    |> validate_tracking(config)
    |> validate_tiers(config)
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

  # Media-time expiry: below ~100 ms a single dropped frame ends every track;
  # above an hour a track outlives the epoch it belongs to. The live-track cap
  # is bounded only against nonsense — 1 is legal and means a scene of one
  # track plus an eviction per new object, which is an operator's choice to
  # make; 10_000 is where it stops being a bound worth having, given a plugin
  # may send 64 objects per line (`Cairn.PluginProtocol`). The stillness
  # threshold is bounded the same way from above — beyond an hour it can never
  # fire inside an epoch — and from below at a second, under which detector
  # jitter, not the object, decides whether something is stationary.
  defp validate_tracking(acc, config) do
    acc
    |> validate_tracking_key(config, :max_unseen_ms, 100, 3_600_000)
    |> validate_tracking_key(config, :max_live_tracks, 1, 10_000)
    |> validate_tracking_key(config, :stationary_after_ms, 1_000, 3_600_000)
  end

  defp validate_tracking_key(acc, config, key, min, max) do
    values =
      [{nil, Map.fetch!(config, key)} | Enum.map(config.cameras, &{&1.id, Map.fetch!(&1, key)})]

    Enum.reduce(values, acc, fn
      {_id, nil}, acc ->
        acc

      {id, value}, acc ->
        prefix = if id, do: "camera #{id}: ", else: "tracking."

        check(acc, int?(value, min, max), "#{prefix}#{key} must be #{min}..#{max}")
    end)
  end

  # Per label, effective `record >= track >= min_score`. A tier below the wire
  # floor can never fire — the plugin drops that band and the host never sees
  # it — so a `record.person` of 0.6 under a `min_score.person` of 0.7 is a
  # rule that silently records nothing. The check runs over the union of labels
  # across all three maps, each resolved through its own default chain, so a
  # tier's catch-all `default:` under a per-label floor is caught as well.
  #
  # "Effective" is what makes the record side asymmetric: an absent `record:`
  # block resolves to the wire floor rather than to nothing, because absent
  # means everything the plugin emits records. A `track:` raised above that
  # floor with no `record:` block therefore leaves a band that films but is
  # never written down. A *present* block that excludes the label is the
  # opposite case and imposes nothing: rows without video is the tier working.
  defp validate_tiers(acc, config) do
    Enum.reduce(config.cameras, acc, &validate_camera_tiers(&2, &1))
  end

  defp validate_camera_tiers(acc, cam) do
    Enum.reduce(tier_labels(cam), acc, fn label, acc ->
      wire = wire_floor(cam.min_score, label)
      track = own_threshold(cam.track, label, cam.min_score)
      record = own_threshold(cam.record, label, cam.min_score)

      acc
      |> check_tier_order(cam.id, label, {"track", track}, {"min_score", wire})
      |> check_tier_order(cam.id, label, {"record", record}, {"min_score", wire})
      |> check_record_covers_track(cam.id, label, track, cam.record, record, wire)
    end)
  end

  # With no `record:` block the effective record threshold is the wire floor,
  # and `track` above it is the gap: video for a detection whose track row is
  # gated out. There is no `record:` key to point the operator at, so the
  # message has to carry the implication.
  defp check_record_covers_track(acc, id, label, track, nil = _rules, _record, wire)
       when is_number(track) do
    check(
      acc,
      wire >= track,
      "camera #{id}: track.#{label} (#{track}) must be <= the effective record threshold " <>
        "(#{wire}) — with no record: block video falls back to min_score, so a clip could " <>
        "exist with no track row. Give #{label} a record: rule, or lower track.#{label}"
    )
  end

  defp check_record_covers_track(acc, id, label, track, _rules, record, _wire) do
    check_tier_order(acc, id, label, {"record", record}, {"track", track})
  end

  # "default" is deliberately left in the union: resolving it through every
  # chain is what compares one block's catch-all against another's.
  defp tier_labels(cam) do
    [cam.min_score, cam.track || %{}, cam.record || %{}]
    |> Enum.flat_map(&Map.keys/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # `nil` where the block is absent, rather than the wire floor
  # `tier_threshold/3` falls back to: against `min_score` an absent block only
  # echoes the floor, so resolving it here would report one violation twice.
  # `check_record_covers_track/7` is the one pairing that does want the floor,
  # and resolves it there.
  defp own_threshold(nil, _label, _min_score), do: nil
  defp own_threshold(rules, label, min_score), do: tier_threshold(rules, label, min_score)

  defp check_tier_order(acc, id, label, {high_key, high}, {low_key, low})
       when is_number(high) and is_number(low) do
    check(
      acc,
      high >= low,
      "camera #{id}: #{high_key}.#{label} (#{high}) must be >= #{low_key}.#{label} (#{low})"
    )
  end

  # A side that is not a number is `:excluded` or an absent block, neither of
  # which is a threshold: a label a tier does not admit imposes no ordering.
  defp check_tier_order(acc, _id, _label, _high, _low), do: acc

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
    |> check(int?(config.retention_tracks_days, 1, 10_000), "retention.tracks_days must be >= 1")
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
