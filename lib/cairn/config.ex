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
  alias Cairn.Config.Profile

  @known_keys ~w(data_dir stall_seconds free_space_min_mb remux_clips udp events retention cameras
                 plugins integrations tracking profile_dirs)
  @known_udp_keys ~w(base_port range)
  @known_events_keys ~w(pre_window_seconds post_window_seconds max_event_seconds)
  @known_retention_keys ~w(days per_label tracks_days)
  @known_integrations_keys ~w(token)
  @known_tracking_keys ~w(max_unseen_ms max_live_tracks stationary_after_ms bbd oru ocr reid)
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
  # No per-camera form, unlike the three bounds above. Those are scene
  # descriptions an operator sets per camera — how long an object may vanish,
  # how crowded the frame is, how long "parked" takes here. This one describes
  # the matcher, and a fleet where half the cameras associate one way and half
  # the other on nothing but per-camera taste is not a thing an operator can
  # reason about or a soak can read.
  #
  # That argument is against a per-*camera* knob, and hardware profiles do not
  # reintroduce one: a profile splits the fleet by plugin group, i.e. by the
  # hardware a group runs on, and names the board it is talking about in a file
  # (`Cairn.Config.Profile`, D-P7). So this key's remaining job is the
  # unprofiled path — the whole answer for a homogeneous fleet, and superseded
  # by the stage list of any group that has a profile, with a load warning
  # naming which side won (`warn_superseded_flags/2`).
  @default_bbd false
  # Whether a track's motion filter is rebuilt across an unmatched gap, from
  # the two real boxes that bound it, instead of being corrected through it
  # (`Cairn.Tracker`'s "Rebuilding a filter across a gap"). Off by default: it
  # replaces a velocity history the filter measured with an interpolation
  # between two sightings, which is the better reading only for as long as the
  # gap is one the pre-gap heading really has nothing to say about, so it is
  # opt-in until soak measurement says otherwise.
  #
  # No per-camera form, for `@default_bbd`'s reason and with its footnote: this
  # describes the motion filter rather than a scene, so it is one answer for
  # every camera not covered by a profile, and a profiled group's stage list
  # supersedes it.
  @default_oru false
  # Off by default: the soak baseline was measured without OCR recovery, and
  # turning it on is phase-6 E2E's to decide, not this default's.
  @default_ocr false
  # Off by default: the appearance fusion is unmeasured until phase-6 E2E, and
  # the veto threshold `Cairn.Tracker.Reid` uses is provisional until then.
  @default_reid false
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
            ocr: @default_ocr,
            reid: @default_reid,
            cameras: [],
            plugin_groups: [],
            profiles: %{},
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
    {profiles, acc} = load_profiles(Map.get(map, "profile_dirs"), acc)
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
      ocr: configured_ocr(map),
      reid: configured_reid(map),
      cameras: cameras,
      plugin_groups: plugin_groups,
      profiles: profiles,
      ha_token: get_in(map, ["integrations", "token"])
    }

    {config, acc} = resolve_plugins(config, acc, declared_plugin_names(map))
    {config, acc} = resolve_profiles(config, acc)
    {config, acc} = expand_profiles(config, acc)
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

  # Not `||`, on the same rule as its two neighbours: a boolean key has to read
  # an explicit `false` as a value rather than as an absence, and only a literal
  # `true` may turn recovery on — a truthy non-boolean in the YAML is a typo,
  # not an opt-in.
  defp configured_ocr(map) do
    case get_in(map, ["tracking", "ocr"]) do
      nil -> @default_ocr
      value -> value === true
    end
  end

  # Not `||`, on the same rule as its three neighbours: a boolean key has to
  # read an explicit `false` as a value rather than as an absence, and only a
  # literal `true` may turn appearance fusion on — a truthy non-boolean in the
  # YAML is a typo, not an opt-in.
  defp configured_reid(map) do
    case get_in(map, ["tracking", "reid"]) do
      nil -> @default_reid
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
          :pre => pos_integer(),
          :post => pos_integer(),
          :max => pos_integer(),
          :max_unseen_ms => pos_integer(),
          :max_live_tracks => pos_integer(),
          :stationary_after_ms => pos_integer(),
          :bbd => boolean(),
          :oru => boolean(),
          :ocr => boolean(),
          :reid => boolean(),
          :track => Camera.tier() | nil,
          :record => Camera.tier() | nil,
          optional(:stages) => %{optional(atom()) => map()}
        }
  def policy(%__MODULE__{} = config, %Camera{} = cam) do
    profile = profile_for(config, cam)

    config
    |> windows(cam)
    |> Map.put(
      :max_unseen_ms,
      bound(cam.max_unseen_ms, profile && profile.max_unseen_ms, config.max_unseen_ms)
    )
    |> Map.put(
      :max_live_tracks,
      bound(cam.max_live_tracks, profile && profile.max_live_tracks, config.max_live_tracks)
    )
    |> Map.put(
      :stationary_after_ms,
      bound(
        cam.stationary_after_ms,
        profile && profile.stationary_after_ms,
        config.stationary_after_ms
      )
    )
    # Straight off the config and not through a `cam` reader: there is no
    # per-camera form of these four (see `@default_bbd`/`@default_oru`/
    # `@default_ocr`/`@default_reid`) — a *profiled* camera ignores the first
    # three entirely, `stages` below superseding them (the load-time warning
    # in `validate_tracking/2` says which wins). `reid` is not a stage and a
    # profile cannot supersede it; it keeps applying to a profiled camera too,
    # for whatever the group's stage list leaves its one seam (`bbd`) able to
    # do (`warn_reid_without_bbd_stage/2` names the case where that is
    # nothing).
    |> Map.put(:bbd, config.bbd)
    |> Map.put(:oru, config.oru)
    |> Map.put(:ocr, config.ocr)
    |> Map.put(:reid, config.reid)
    |> Map.put(:track, cam.track)
    |> Map.put(:record, cam.record)
    |> put_stages(profile)
  end

  # The three bounds resolve camera → profile → global: a camera's own
  # override outranks its group's profile (the operator spoke about *this*
  # scene), and the profile's band-tuned defaults outrank the globals.
  defp bound(camera, profile, global), do: camera || profile || global

  # The whole of what a profile changes about tracking policy: the stage
  # presence map replaces the boolean flags for every camera on the profiled
  # group. Unprofiled cameras — and cameras on a profile that had no
  # `tracking:` block, which said nothing about tracking — get no `stages`
  # key at all, which is what keeps their path (through
  # `Cairn.CameraTracker.tracking_policy/1` and `Cairn.Tracker.context/3`)
  # the pre-profile one bit for bit.
  defp put_stages(policy, nil), do: policy
  defp put_stages(policy, %Profile{stages: nil}), do: policy
  defp put_stages(policy, %Profile{stages: stages}), do: Map.put(policy, :stages, stages)

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

  @doc "Whether observation-centric recovery is on when no config is available."
  @spec default_ocr() :: boolean()
  def default_ocr, do: @default_ocr

  @doc "Whether Re-ID appearance fusion is on when no config is available."
  @spec default_reid() :: boolean()
  def default_reid, do: @default_reid

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

  # -- profiles ---------------------------------------------------------------

  # Shipped profiles first, operator dirs after — `Profile.load_dirs/2` gives
  # later files the name on a collision (with a warning), so an operator file
  # shadows a shipped one. The shipped dir not existing is the normal state
  # until built-in profiles land; nothing warns about it.
  defp load_profiles(dirs, acc) do
    case dirs do
      nil ->
        Profile.load_dirs([shipped_profiles_dir()], acc)

      dirs when is_list(dirs) ->
        if Enum.all?(dirs, &is_binary/1) do
          Profile.load_dirs([shipped_profiles_dir() | dirs], acc)
        else
          {%{}, add_error(acc, "profile_dirs must be a list of directory paths")}
        end

      _other ->
        {%{}, add_error(acc, "profile_dirs must be a list of directory paths")}
    end
  end

  defp shipped_profiles_dir, do: Application.app_dir(:cairn, "priv/profiles")

  # The second half of the two-pass shape `resolve_plugins/3` uses for camera
  # plugin references: a group's `profile:` name becomes the parsed
  # `Cairn.Config.Profile` struct, or (typo, missing file) a config error
  # naming what was looked for.
  defp resolve_profiles(config, acc) do
    {groups, acc} =
      Enum.map_reduce(config.plugin_groups, acc, fn
        %PluginGroup{profile: name} = group, acc when is_binary(name) ->
          case Map.fetch(config.profiles, name) do
            {:ok, profile} ->
              {%{group | profile: profile}, acc}

            :error ->
              {%{group | profile: nil},
               add_error(
                 acc,
                 "plugin #{group.name}: unknown profile #{inspect(name)} — no such file " <>
                   "in priv/profiles or any profile_dirs entry"
               )}
          end

        group, acc ->
          {group, acc}
      end)

    {%{config | plugin_groups: groups}, acc}
  end

  @doc """
  The profile resolved for a camera's plugin group, or `nil` for a camera on
  no group or on an unprofiled one.

  This is the group→camera hop `policy/2` reads: cameras do not know their
  group's profile, but they do know their group (`cam.plugin` is resolved to
  `{:group, name}` at load), and the config holds the rest.
  """
  @spec profile_for(t(), Camera.t()) :: Profile.t() | nil
  def profile_for(%__MODULE__{} = config, %Camera{plugin: {:group, name}}) do
    case Enum.find(config.plugin_groups, &(&1.name == name)) do
      %PluginGroup{profile: %Profile{} = profile} -> profile
      _other -> nil
    end
  end

  def profile_for(%__MODULE__{}, %Camera{}), do: nil

  # -- profile argv expansion -------------------------------------------------

  # The six flags a profile owns for its group, and the only argv
  # `Cairn.Config` ever writes. `--motion-json` and `--track-floor-json` are
  # deliberately absent: they describe the scene, not the model, and stay the
  # operator's own (D-P6).
  @model_flags ~w(--model --model-profile --input-size --decoder --labels --sample-fps)

  # One compiled word-boundary regex per flag, built once rather than per
  # `flag?/2` call: a flag counts as present at token-start or after
  # whitespace or a shell quote, followed by `=`, whitespace, a shell quote,
  # or end-of-token — so `--model` matches inside
  # `"exec cairn-detect --model x"` and its quoted form
  # `"exec cairn-detect '--model' x"` (sh strips the quotes before the
  # plugin sees the flag) but not `--model-profile` or a path like
  # `/opt/--model/x`.
  @model_flag_regexes Map.new(@model_flags, fn flag ->
                        {flag,
                         Regex.compile!("(^|[\\s\"'])" <> Regex.escape(flag) <> "(=|[\\s\"']|$)")}
                      end)

  # Where a profile stops being data and becomes the plugin's argv. Expanding
  # into `group.command` at load — rather than teaching
  # `Cairn.PluginGroupPort.build_argv/1` to read a profile — is what keeps the
  # port and the process it owns profile-unaware, and it is what makes a
  # profile edit reach the plugin at all: the group's restart trigger is a
  # changed struct (`Cairn.Config.Server.diff_plugin_groups/2`), so the flags
  # have to be *in* the struct.
  defp expand_profiles(config, acc) do
    {groups, acc} = Enum.map_reduce(config.plugin_groups, acc, &expand_group/2)

    {%{config | plugin_groups: groups}, acc}
  end

  defp expand_group(%PluginGroup{profile: %Profile{} = profile} = group, acc) do
    acc =
      acc
      |> check_single_source(group, profile)
      |> check_backend_implemented(group, profile)
      |> check_artifact(group, profile)
      |> check_labels(profile)

    {%{group | command: group.command ++ profile_argv(profile)}, acc}
  end

  defp expand_group(group, acc), do: {group, acc}

  # Only the fields the profile actually set: an unset one emits no flag at
  # all rather than a default, leaving the plugin's own fallback in force —
  # `--model-profile` and `--input-size` are both sniffed from the model when
  # absent, and a value guessed here would defeat that. `--sample-fps` follows
  # the same rule for a different reason: `fps_band:` only *validates* a
  # declared `sample_fps:` (`Profile.check_sample_fps/3`, D-P4) and is never
  # itself a source for the flag, so a profile with a band and no
  # `sample_fps:` emits nothing here, bit-identical to before this field
  # existed.
  defp profile_argv(%Profile{} = profile) do
    flag("--model", Profile.artifact(profile)) ++
      flag("--model-profile", profile.model_profile) ++
      flag("--input-size", profile.input_size) ++
      flag("--decoder", profile.decoder) ++
      flag("--labels", profile.labels) ++
      flag("--sample-fps", profile.sample_fps)
  end

  defp flag(_name, nil), do: []
  defp flag(name, value), do: [name, to_string(value)]

  # D-P4: cross-boundary consistency by construction. Elixir expands both the
  # Rust argv and the tracker's stage list from one file, which is only true
  # for as long as nothing else writes the model argv — so an operator flag
  # naming any of the six is an error, not a silent race between two answers
  # settled by whatever clap does with a repeated flag. `flag?/2` counts an
  # occurrence anywhere inside a token, not just a whole token, so an operator
  # shell-wrapping the command (`["/bin/sh", "-c", "exec plugin --model x"]`)
  # cannot smuggle a model flag past this check and silently drop the
  # profile's own.
  defp check_single_source(acc, group, profile) do
    Enum.reduce(@model_flags, acc, fn flag, acc ->
      check(
        acc,
        not Enum.any?(group.command, &flag?(&1, flag)),
        "plugin #{group.name}: command carries #{flag}, which profile #{profile.name} owns — " <>
          "a profiled group's model flags (#{Enum.join(@model_flags, ", ")}) come from its " <>
          "profile alone; drop #{flag} from command:"
      )
    end)
  end

  defp flag?(token, flag), do: Regex.match?(Map.fetch!(@model_flag_regexes, flag), token)

  # D-P10: `rknn` and `qnn` are legal names in a profile — the schema knows
  # them so board profiles can ship before their backends do — but a group
  # actually running one needs both halves of the acknowledgement, the
  # profile's own `experimental:` and the operator's `allow_experimental:`.
  # Refused at load rather than at group start because this is where an
  # operator reads diagnostics; a start-time refusal is a respawn loop in a
  # log file nobody is tailing.
  defp check_backend_implemented(acc, _group, %Profile{backend: "ort"}), do: acc

  defp check_backend_implemented(acc, group, %Profile{experimental: false} = profile) do
    add_error(
      acc,
      "plugin #{group.name}: profile #{profile.name} uses backend #{profile.backend}, which is " <>
        "not yet implemented — only ort executes today, and a profile naming another backend " <>
        "must declare experimental: true"
    )
  end

  defp check_backend_implemented(acc, %PluginGroup{allow_experimental: false} = group, profile) do
    add_error(
      acc,
      "plugin #{group.name}: profile #{profile.name} uses backend #{profile.backend}, which is " <>
        "not yet implemented — set allow_experimental: true on this plugin group to run it anyway"
    )
  end

  defp check_backend_implemented(acc, _group, _profile), do: acc

  # The artifact is checked verbatim, against this node's working directory,
  # because that is the one the plugin process is spawned from and reads it
  # in: resolving the path against the config file or the profile file would
  # check one file and hand the plugin another.
  #
  # A profile naming no artifact is refused too, rather than left to expand
  # into nothing: a profile is a model choice before it is anything else, and
  # D-P4 has just forbidden the operator from writing `--model` themselves —
  # so a profiled group with no artifact could only ever run a model nobody
  # named.
  defp check_artifact(acc, group, profile) do
    case Profile.artifact(profile) do
      nil ->
        add_error(
          acc,
          "plugin #{group.name}: profile #{profile.name} names no " <>
            "model.#{Profile.artifact_key(profile.backend)} artifact for its #{profile.backend} " <>
            "backend — a profiled group takes --model from its profile alone"
        )

      path ->
        check(
          acc,
          File.regular?(path),
          "profile #{profile.name}: model artifact #{path} does not exist or is not a " <>
            "regular file (relative paths resolve against the working directory the plugin " <>
            "is spawned from)"
        )
    end
  end

  # The labels file gets the artifact's treatment for the artifact's reason:
  # it is a path this config expands into `--labels`, read by the plugin
  # against the same cwd. Absence is not an error here the way a missing
  # artifact is: `--labels` is optional to the plugin (class ids stand in for
  # names without it), where a profiled group with no `--model` could only ever
  # run a model nobody named.
  defp check_labels(acc, %Profile{labels: nil}), do: acc

  defp check_labels(acc, %Profile{labels: path} = profile) do
    check(
      acc,
      File.regular?(path),
      "profile #{profile.name}: labels file #{path} does not exist or is not a regular " <>
        "file (relative paths resolve against the working directory the plugin is " <>
        "spawned from)"
    )
  end

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
    |> validate_profile_bounds(config)
    |> validate_reid_requires_bbd(config)
    |> warn_superseded_flags(config)
    |> warn_reid_without_bbd_stage(config)
  end

  # Reid's fusion has one seam into the tracker: the BBD admission
  # (`Cairn.Tracker.Reid`, `Cairn.Tracker.Stage.Bbd`). The global bbd flag
  # governs exactly the cameras on *unprofiled* groups (D-P7), so the refusal
  # is scoped to them: reid on, global bbd off, and at least one camera the
  # global flag actually reaches is a configuration that can never act there
  # — refused rather than accepted and left inert. A fully-profiled config
  # answers to its profiles' own stage lists instead, where the per-group
  # warning (`warn_reid_without_bbd_stage/2`) names any profile that
  # silences reid — legitimately reid-capable profiles must not be refused
  # over a global flag their cameras never read.
  defp validate_reid_requires_bbd(acc, config) do
    # "Unprofiled" spans both shapes the global flag reaches: a camera with
    # its own inline plugin command, and a member of a group that has no
    # profile. A camera with no plugin at all runs no tracker and holds no
    # opinion.
    unprofiled? =
      Enum.any?(config.cameras, fn
        %{plugin: {:inline, _argv}} -> true
        %{plugin: {:group, _name}} = cam -> profile_for(config, cam) == nil
        _camera -> false
      end)

    check(
      acc,
      not config.reid or config.bbd or not unprofiled?,
      "tracking.reid requires tracking.bbd: the appearance fusion lives inside the BBD " <>
        "admission and can never act without it (unprofiled cameras read the global flag)"
    )
  end

  # A profile's band-tuned bounds go through `bound/3` into the same tracker
  # the global and camera values reach, so they answer to the same ranges —
  # checked here rather than in `Profile.parse/3` so the numbers live in one
  # place, beside the global checks they mirror.
  defp validate_profile_bounds(acc, config) do
    ranges = [
      {:max_unseen_ms, 100, 3_600_000},
      {:max_live_tracks, 1, 10_000},
      {:stationary_after_ms, 1_000, 3_600_000}
    ]

    for {_name, profile} <- config.profiles, {key, min, max} <- ranges, reduce: acc do
      acc ->
        case Map.fetch!(profile, key) do
          nil ->
            acc

          value when is_integer(value) and value >= min and value <= max ->
            acc

          value ->
            add_error(
              acc,
              "profile #{profile.name}: tracking.#{key} must be an integer between " <>
                "#{min} and #{max}, got #{inspect(value)}"
            )
        end
    end
  end

  # D-P7: the global booleans keep working for cameras on unprofiled groups,
  # a profiled group ignores them, and setting both is legal but ambiguous
  # enough to name — one warning per profiled group, saying which side wins.
  defp warn_superseded_flags(acc, config) do
    if config.bbd or config.oru or config.ocr do
      config.plugin_groups
      |> Enum.filter(&match?(%Profile{}, &1.profile))
      |> Enum.reduce(acc, fn group, acc ->
        add_warning(
          acc,
          "plugin #{group.name}: profile #{group.profile.name} supersedes the global " <>
            "tracking.bbd/oru/ocr flags for its cameras — the profile's stage list wins"
        )
      end)
    else
      acc
    end
  end

  # `reid` is not a stage — a profile has no key for it and cannot list or
  # delist it (see the comment on `policy/2`) — so it is never superseded the
  # way `warn_superseded_flags/2` warns about. But its one seam is the bbd
  # *stage*, and a profiled group whose stage list replaces the booleans and
  # leaves bbd out silences it for that group's cameras just as surely as the
  # global bbd flag being off would — worth naming, since nothing else here
  # would tell an operator reid is doing nothing on that hardware.
  defp warn_reid_without_bbd_stage(acc, config) do
    if config.reid do
      config.plugin_groups
      |> Enum.filter(&reid_silenced_by_profile?/1)
      |> Enum.reduce(acc, fn group, acc ->
        add_warning(
          acc,
          "tracking.reid has no effect for group #{group.name}: its profile " <>
            "#{group.profile.name} lists no bbd stage"
        )
      end)
    else
      acc
    end
  end

  # A profile with no `tracking:` block at all (`stages: nil`) says nothing
  # about tracking, so the group's cameras fall back to the global `bbd` flag
  # like any unprofiled camera — not this function's case. Only a profile that
  # *does* carry a stage list and leaves bbd off it silences reid.
  defp reid_silenced_by_profile?(%PluginGroup{profile: %Profile{stages: stages}})
       when is_map(stages),
       do: not Map.has_key?(stages, :bbd)

  defp reid_silenced_by_profile?(_group), do: false

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
