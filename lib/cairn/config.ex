defmodule Cairn.Config do
  @moduledoc """
  Typed application configuration loaded from a YAML file.

  `load/1` parses and validates the file, returning `{:ok, config, warnings}`
  or `{:error, errors}`. Validation is strict on errors (bad values, missing
  required fields) and lenient on unknown keys, which only produce warnings —
  which is also how a pre-phase-6 config's `udp:` block ages out. One
  deliberate exception: an unknown key *inside* a `track:` / `record:` tier
  rule is an error, because a filter this codebase does not implement yet
  must not look applied (`Cairn.Config.Camera`).

  `CAIRN_DATA_DIR` (env) overrides `data_dir` from the file.
  """

  alias Cairn.Config.Camera
  alias Cairn.Config.PluginGroup
  alias Cairn.Config.Profile
  # `as:` because this module is a `Config` of its own — the engine's
  # vocabulary and the operator's file are two different things.
  alias Cairn.Native.Config, as: NativeConfig

  @known_keys ~w(data_dir stall_seconds free_space_min_mb remux_clips events retention cameras
                 plugins integrations tracking profile_dirs)
  @known_events_keys ~w(pre_window_seconds post_window_seconds max_event_seconds)
  @known_retention_keys ~w(days per_label tracks_days)
  @known_integrations_keys ~w(token)
  @known_tracking_keys ~w(max_unseen_ms max_live_tracks stationary_after_ms bbd oru ocr reid
                          tracker)
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
  # Which tracker core `Membrane.MOTTracker` hosts. The menu is names rather
  # than module atoms so a config file cannot name an arbitrary module, and it
  # is validated at load: a typo is a config error, not a pipeline that raises
  # when the camera it belongs to starts streaming.
  #
  # `sparsetrack` is the vendored-reference port behind its cairn-side units
  # and vocabulary adapter (`Cairn.Detect.SparseTrack`); it is selectable and
  # deliberately not the default — flipping that is a decision for after it has
  # been measured on real cameras rather than on MOT sequences.
  @trackers %{"cairn" => Cairn.Tracker, "sparsetrack" => Cairn.Detect.SparseTrack}
  @default_tracker "cairn"
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
            tracker: @default_tracker,
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
      tracker: configured_tracker(map),
      cameras: cameras,
      plugin_groups: plugin_groups,
      profiles: profiles,
      ha_token: get_in(map, ["integrations", "token"])
    }

    {config, acc} = resolve_plugins(config, acc, declared_plugin_names(map))
    {config, acc} = resolve_ladders(config, acc)
    {config, acc} = resolve_profiles(config, acc)
    acc = check_group_profiles(config, acc)
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

  # A name, not a module: `validate_trackers/2` refuses one no core answers to,
  # and `tracker/2` resolves what survives that. Not `||`, on the rule its
  # boolean neighbours above follow for their own reason: only an absent key is
  # a default, so a `false` in the YAML reaches the validator as the name it is
  # not, rather than being read as an absence and silently defaulted.
  defp configured_tracker(map) do
    case get_in(map, ["tracking", "tracker"]) do
      nil -> @default_tracker
      name -> name
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

  `Cairn.PipelineOwner` resolves it off the per-frame path — when it builds
  the pipeline and again on each `refresh/3` — and the pipeline's detect branch
  reads it at both ends: `Cairn.Pipeline.ObservationStamper` resolves the
  tracking context from it, and `Cairn.Pipeline.TrackSink` hands it to
  `Cairn.Detect.Dispatch` with every batch unmodified. So no camera tracker
  calls the config server per frame, and a key added here reaches
  `Cairn.CameraTracker`. A *running* camera gets a changed policy only through
  that refresh.

  `:track` and `:record` are the camera's parsed tiers verbatim, `nil` when
  the block is absent. Resolve a label against one with `tier_threshold/3`
  rather than reading the map directly — `nil` and an unlisted label mean
  opposite things.

  Two keys appear only when a profile put them there — `:stages` (the
  group's stage presence map) and `:tier` (the profile's capability rung,
  no relation to the score tiers above) — so their absence is itself the
  answer "the profile said nothing".
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
          optional(:stages) => %{optional(atom()) => map()},
          optional(:tier) => 1..2
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
    |> put_tier(profile)
  end

  # The three bounds resolve camera → profile → global: a camera's own
  # override outranks its group's profile (the operator spoke about *this*
  # scene), and the profile's band-tuned defaults outrank the globals.
  defp bound(camera, profile, global), do: camera || profile || global

  @doc """
  The tracker core `Membrane.MOTTracker` hosts for a camera, resolved
  camera → profile → global on `bound/3`'s precedence.

  A module, not a name: the names are the config vocabulary and `validate/2`
  has already refused any that no core answers to, so nothing downstream has to
  handle one that does not resolve.

  Read where the pipeline is built rather than carried in `policy/2`: the core
  is wired into the branch at birth, and a reload cannot re-wire an element.
  """
  @spec tracker(t(), Camera.t()) :: module()
  def tracker(%__MODULE__{} = config, %Camera{} = cam) do
    profile = profile_for(config, cam)

    Map.fetch!(@trackers, named_tracker(cam.tracker, profile && profile.tracker, config.tracker))
  end

  # `bound/3`'s precedence, but coalescing on `nil` alone: an override is
  # absent or it is a name, and a `false` that fell through `||` here would be
  # resolved to the default the load-time validator had already refused it in
  # favour of — turning a rejected config into a silently running one.
  defp named_tracker(nil, nil, global), do: global
  defp named_tracker(nil, profile, _global), do: profile
  defp named_tracker(camera, _profile, _global), do: camera

  @doc """
  The rate a camera's detect branch delivers frames at: its profile's
  `sample_fps`, or the engine default a profile that names none leaves it to.

  Nothing is told to thin by reading this — `Cairn.Pipeline.Decoder` already
  gates on the rate `Cairn.Native.Host` opened its decoder with, which is this
  same profile field — so it is a reading, for the elements whose own
  arithmetic counts frames.
  """
  @spec sample_fps(t(), Camera.t()) :: pos_integer()
  def sample_fps(%__MODULE__{} = config, %Camera{} = cam) do
    profile = profile_for(config, cam)

    (profile && profile.sample_fps) || NativeConfig.default_sample_fps()
  end

  @doc "The tracker-core names a config may choose between, for error messages."
  @spec tracker_names() :: [String.t()]
  def tracker_names, do: @trackers |> Map.keys() |> Enum.sort()

  # The whole of what a profile changes about tracking policy: the stage
  # presence map replaces the boolean flags for every camera on the profiled
  # group. Unprofiled cameras — and cameras on a profile that had no
  # `tracking:` block, which said nothing about tracking — get no `stages`
  # key at all, which is what keeps their path (through
  # `Cairn.Pipeline.ObservationStamper`'s `tracking_policy/2` and
  # `Cairn.Tracker.context/3`) the pre-profile one bit for bit.
  defp put_stages(policy, nil), do: policy
  defp put_stages(policy, %Profile{stages: nil}), do: policy
  defp put_stages(policy, %Profile{stages: stages}), do: Map.put(policy, :stages, stages)

  # The capability tier (`Profile` `tier:`, the ascending ladder — not the
  # `:track`/`:record` score tiers above), on `put_stages/2`'s shape: no key
  # at all for a tier-less profile, which is what keeps every existing
  # config's policy map — and everything hashed or asserted off it — bit
  # identical (D-S5). Read by the tier-1 presence fork
  # (`Cairn.Pipeline.Camera.detect_tail/4`) and by `Cairn.Config.Server`'s
  # restart classification; the tier-2 gate rule is still to come.
  defp put_tier(policy, %Profile{tier: tier}) when tier != nil,
    do: Map.put(policy, :tier, tier)

  defp put_tier(policy, _absent_or_tierless), do: policy

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

    {%{config | cameras: cameras}, acc}
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
           "camera #{cam.id}: unknown plugin #{inspect(name)} — define it under plugins:"
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

  # -- ladder resolution ------------------------------------------------------

  # Static, at config load/reload (D-L1): N is the count of cameras with
  # detection *configured* — a camera naming a plugin — never the runtime
  # detection toggle, which must not re-resolve anything (capacity sizes for
  # the configured fleet; no flapping). Runs before `resolve_profiles/2` so
  # the structs it lowers are the ones the groups get, and only for profiles
  # some CAMERA detects on — not merely ones a group names: a spare group
  # defined but used by no camera runs nothing, and resolving its ladder
  # against a fleet it does not serve could fail the load over cameras that
  # never touch it. An unused ladder file costs no disk probes and no
  # warnings, like the artifact checks below.
  #
  # "Lowers": the selected rung's model fields and the derived sample_fps are
  # written into the profile's own single-model fields, so everything
  # downstream — `native_model_config/1` and its one-model-per-VM refusal,
  # `sample_fps/2`, the artifact checks, `Cairn.Config.Server`'s resolved
  # comparisons — reads a ladder profile as the single-model profile it
  # resolved to. `resolved_rung` keeps the selection itself for the
  # restart-class comparison (D-L5).
  defp resolve_ladders(config, acc) do
    # Group name → profile name; groups still hold name strings here
    # (`resolve_profiles/2` runs after this pass).
    by_group =
      Map.new(config.plugin_groups, fn
        %PluginGroup{name: group, profile: profile} when is_binary(profile) -> {group, profile}
        %PluginGroup{name: group} -> {group, nil}
      end)

    used =
      MapSet.new(
        for %Camera{plugin: {:group, group}} <- config.cameras,
            profile = Map.get(by_group, group),
            is_binary(profile),
            do: profile
      )

    n = Enum.count(config.cameras, &(&1.plugin != nil))

    {profiles, acc} =
      Enum.map_reduce(config.profiles, acc, fn
        {name, %Profile{model_ladder: rungs} = profile}, acc when is_list(rungs) ->
          if MapSet.member?(used, name) do
            {profile, acc} = resolve_ladder(profile, n, acc)
            {{name, profile}, acc}
          else
            {{name, profile}, acc}
          end

        entry, acc ->
          {entry, acc}
      end)

    {%{config | profiles: Map.new(profiles)}, acc}
  end

  defp resolve_ladder(profile, n, acc) do
    # Parse guarantees a ladder profile's tier has a floor row.
    floor = Profile.ladder_floor(profile.tier)
    demand = n * Profile.effective_rate(floor.floor_fps)
    indexed = Enum.with_index(profile.model_ladder, 1)

    # D-L4: a pack rung whose artifact is not on disk is skipped, warned; a
    # non-pack rung is always a candidate — a missing artifact there is the
    # load error `check_ladder_artifacts/2` raises, not a silent skip.
    {candidates, skipped} =
      Enum.split_with(indexed, fn {rung, _index} ->
        rung.pack == nil or File.regular?(rung_artifact(rung, profile.backend))
      end)

    fits = fn {rung, _index} -> rung.engine_budget >= demand end
    selected = Enum.find(candidates, fits)
    # What resolution WOULD pick were every pack installed — named in the
    # skip warning so an operator knows which install buys accuracy now.
    would_be = Enum.find(indexed, fits)

    acc = Enum.reduce(skipped, acc, &warn_skipped_rung(&2, &1, profile, n, would_be))

    case selected do
      nil ->
        {profile, add_error(acc, no_rung_fits(profile, n, floor, candidates))}

      {rung, _index} ->
        {lower_ladder(profile, rung, n, floor), acc}
    end
  end

  defp rung_artifact(rung, backend), do: Map.get(rung.model, Profile.artifact_key(backend))

  defp warn_skipped_rung(acc, {rung, index} = entry, profile, n, would_be) do
    suffix =
      if entry == would_be do
        " — #{n} camera(s) would get this rung's model; installing the pack raises " <>
          "their accuracy at the same capacity"
      else
        ""
      end

    add_warning(
      acc,
      "profile #{profile.name}: ladder rung #{index} (pack #{rung.pack}) skipped — " <>
        "artifact #{rung_artifact(rung, profile.backend)} is not installed#{suffix}"
    )
  end

  defp no_rung_fits(profile, n, floor, candidates) do
    # Budgets increase down the list, so the last candidate is the largest;
    # D-L2 guarantees candidates is non-empty (a non-pack rung always is one).
    {largest, _index} = List.last(candidates)
    floor_rate = Profile.effective_rate(floor.floor_fps)

    "profile #{profile.name}: no ladder rung covers #{n} cameras at tier " <>
      "#{profile.tier}'s #{floor.floor_fps} fps floor (#{floor_rate}/s effective) — " <>
      "the largest eligible rung (#{rung_artifact(largest, profile.backend)}) budgets " <>
      "#{largest.engine_budget} passes/s, about #{trunc(largest.engine_budget / floor_rate)} " <>
      "cameras. Remove cameras from this node's detecting groups or split the node"
  end

  # The derived rate (D-L4): the largest nominal fps within the tier's bounds
  # whose EFFECTIVE demand fits the rung's budget. Chosen over
  # `trunc(budget / n)` deliberately: the gate quantizes to the frame grid,
  # so at 10 cameras on a 75/s budget the largest fitting nominal is 10
  # (7.5/s effective each, exactly the measured-uniform knee), where
  # truncation would configure 7 — which the grid degrades to 5.0/s each and
  # a third of the measured budget goes unspent. Rounding up unguarded is the
  # opposite failure: 20 cameras on 52.6/s would round 2.63 to a nominal 3,
  # 3.0/s effective, 60/s demand — past the budget into the regime where
  # throughput measurably regresses.
  defp lower_ladder(profile, rung, n, floor) do
    fps =
      Enum.find(floor.cap_fps..floor.floor_fps//-1, floor.floor_fps, fn fps ->
        n * Profile.effective_rate(fps) <= rung.engine_budget
      end)

    %{
      profile
      | model: rung.model,
        model_profile: rung.model_profile || profile.model_profile,
        input_size: rung.input_size,
        sample_fps: fps,
        resolved_rung: rung
    }
  end

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

  @doc """
  The ladder rung load-time resolution picked for a camera's profile, or
  `nil` for a camera off the ladder path.

  `Cairn.Config.Server` compares it resolved across a reload (D-L5): adding
  or removing cameras elsewhere on the node can move N across a rung
  boundary, which is a model change for THIS camera — restart-class, through
  the existing engine-first reload ordering — without a single field of its
  own having moved.
  """
  @spec resolved_rung(t(), Camera.t()) :: map() | nil
  def resolved_rung(%__MODULE__{} = config, %Camera{} = cam) do
    profile = profile_for(config, cam)
    profile && profile.resolved_rung
  end

  @doc """
  The model this node's in-VM engine should load, in
  `Cairn.Native.Config.normalize/1`'s vocabulary, or `nil` when no camera
  names a profile.

  Cameras detect in `Cairn.Native.Host`, one engine and one model for the
  whole VM, so several cameras asking for different models is a config
  nothing can satisfy — refused at load, where an operator reads
  diagnostics, rather than at the first camera to lose its detector.

  Scene config is not here: `min_score` and the motion/track-floor scene
  knobs are the operator's per-stream params
  (`Cairn.Native.Config.stream_params/1`) and a profile never writes them
  (D-P6). The one profile-shaped word on the subject is a refusal: a
  tier-2 group rejects a camera's `motion_json` outright
  (`validate_gate_ownership/2`, D-S4).
  """
  @spec native_model_config(t()) :: {:ok, map() | nil} | {:error, String.t()}
  def native_model_config(%__MODULE__{} = config) do
    config.cameras
    |> Enum.map(&profile_for(config, &1))
    # What a load lets through here is a camera with no plugin at all:
    # `validate_camera_profiles/2` refuses every other unprofiled one.
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(&Profile.native_config/1)
    |> case do
      [] -> {:ok, nil}
      [profile] -> {:ok, Profile.native_config(profile)}
      profiles -> {:error, disagreeing_profiles(profiles)}
    end
  end

  defp disagreeing_profiles(profiles) do
    names = profiles |> Enum.map(&(&1.name || "(unnamed)")) |> Enum.sort() |> Enum.join(", ")

    "cameras run on profiles that ask for different models (#{names}) — this node " <>
      "loads one model for every camera, so their plugin groups must agree"
  end

  # -- group profile checks -----------------------------------------------

  # What survives of the profile→argv expansion the external plugin path
  # used: the profile a group names is what the in-VM engine will load, so
  # its backend gate, artifact and labels paths are still checked at load,
  # where an operator reads diagnostics.
  defp check_group_profiles(config, acc) do
    Enum.reduce(config.plugin_groups, acc, &check_group_profile/2)
  end

  defp check_group_profile(%PluginGroup{profile: %Profile{} = profile} = group, acc) do
    acc
    |> check_backend_implemented(group, profile)
    |> check_artifact(group, profile)
    |> check_ladder_artifacts(profile)
    |> check_labels(profile)
  end

  defp check_group_profile(_group, acc), do: acc

  # D-P10: `rknn` and `qnn` are legal names in a profile — the schema knows
  # them so board profiles can ship before their backends do — but a group
  # actually running one needs both halves of the acknowledgement, the
  # profile's own `experimental:` and the operator's `allow_experimental:`.
  # The gate is the same whether the backend is a plugin-side stub (rknn)
  # or executes but has not soaked (qnn since the phase-2 wiring): non-ort
  # means experimental until this comment says otherwise. Refused at load
  # rather than at group start because this is where an operator reads
  # diagnostics; a start-time refusal is a respawn loop in a log file
  # nobody is tailing.
  defp check_backend_implemented(acc, _group, %Profile{backend: "ort"}), do: acc

  defp check_backend_implemented(acc, group, %Profile{experimental: false} = profile) do
    add_error(
      acc,
      "plugin #{group.name}: profile #{profile.name} uses backend #{profile.backend}, which is " <>
        "experimental — only ort is proven in soak, and a profile naming another backend " <>
        "must declare experimental: true"
    )
  end

  defp check_backend_implemented(acc, %PluginGroup{allow_experimental: false} = group, profile) do
    add_error(
      acc,
      "plugin #{group.name}: profile #{profile.name} uses backend #{profile.backend}, which is " <>
        "experimental — set allow_experimental: true on this plugin group to run it anyway"
    )
  end

  defp check_backend_implemented(acc, _group, _profile), do: acc

  # The artifact is checked verbatim, against this node's working directory,
  # because that is the one the engine resolves it in: resolving the path
  # against the config file or the profile file would check one file and
  # hand the engine another.
  #
  # A profile naming no artifact is refused too: a profile is a model choice
  # before it is anything else, so a group whose profile names none could
  # only ever run a model nobody named.
  # A ladder profile that failed resolution was never lowered, so its model
  # fields are empty by construction — the resolution error already says why,
  # and "names no artifact" on top would send the operator at the wrong key.
  defp check_artifact(acc, _group, %Profile{model_ladder: rungs, resolved_rung: nil})
       when is_list(rungs),
       do: acc

  defp check_artifact(acc, group, profile) do
    case Profile.artifact(profile) do
      nil ->
        add_error(
          acc,
          "plugin #{group.name}: profile #{profile.name} names no " <>
            "model.#{Profile.artifact_key(profile.backend)} artifact for its #{profile.backend} " <>
            "backend — the engine takes its model from the profile alone"
        )

      path ->
        check(
          acc,
          File.regular?(path),
          "profile #{profile.name}: model artifact #{path} does not exist or is not a " <>
            "regular file (relative paths resolve against this node's working directory)"
        )
    end
  end

  # D-L2's disk half: pack rungs may be absent (resolution skips them, with a
  # warning), but a non-pack rung is the shipped container's own promise, so
  # each one gets `check_artifact/3`'s must-exist treatment — not only the
  # selected rung, because the rung a fleet edit selects tomorrow has to be
  # loadable then. The selected rung is skipped here: lowering already routed
  # it through `check_artifact/3`.
  defp check_ladder_artifacts(acc, %Profile{model_ladder: rungs} = profile)
       when is_list(rungs) do
    rungs
    |> Enum.with_index(1)
    |> Enum.filter(fn {rung, _index} -> rung.pack == nil and rung != profile.resolved_rung end)
    |> Enum.reduce(acc, fn {rung, index}, acc ->
      path = Map.get(rung.model, Profile.artifact_key(profile.backend))

      check(
        acc,
        File.regular?(path),
        "profile #{profile.name}: ladder rung #{index} model artifact #{path} does not " <>
          "exist or is not a regular file (relative paths resolve against this node's " <>
          "working directory) — non-pack rungs must always be loadable (Apache-complete " <>
          "invariant)"
      )
    end)
  end

  defp check_ladder_artifacts(acc, _profile), do: acc

  # The labels file gets the artifact's treatment for the artifact's reason:
  # it is a path the engine reads against the same cwd. Absence is not an
  # error here the way a missing artifact is: labels are optional (class ids
  # stand in for names without them), where a profile with no model could
  # only ever run one nobody named.
  defp check_labels(acc, %Profile{labels: nil}), do: acc

  defp check_labels(acc, %Profile{labels: path} = profile) do
    check(
      acc,
      File.regular?(path),
      "profile #{profile.name}: labels file #{path} does not exist or is not a regular " <>
        "file (relative paths resolve against this node's working directory)"
    )
  end

  # -- validation -------------------------------------------------------------

  defp validate(config, acc) do
    acc
    |> validate_ids(config)
    |> validate_plugins(config)
    |> validate_windows(config)
    |> validate_tracking(config)
    |> validate_tiers(config)
    |> validate_numbers(config)
    |> validate_remux(config)
    |> validate_ha_token(config)
    |> validate_native_model(config)
    |> validate_camera_profiles(config)
    |> validate_gate_ownership(config)
  end

  # D-S4, the one contradiction config polices between the tiers and the
  # operator's scene knobs: a tier-2 profile claims accuracy the motion
  # gate would silently starve (frames the gate skips are frames the
  # tracker never sees), so a camera carrying `motion_json:` on a tier-2
  # group is an error naming both sides. Tier 1 runs the gate by design
  # and tier-less keeps today's behavior — both pass untouched, and config
  # never WRITES a motion flag on anyone's behalf (D-P6 survives for the
  # thresholds).
  defp validate_gate_ownership(acc, config) do
    config.cameras
    |> Enum.filter(fn cam ->
      cam.motion_json != nil and match?(%Profile{tier: 2}, profile_for(config, cam))
    end)
    |> Enum.reduce(acc, fn cam, acc ->
      add_error(
        acc,
        "camera #{cam.id}: motion_json contradicts its group's tier: 2 profile — " <>
          "tier 2 claims accurate MOT, and a motion gate starves the tracker of exactly " <>
          "the frames it skips. Remove the camera's motion_json, or claim tier: 1 " <>
          "(presence) on the profile, which runs gated by design"
      )
    end)
  end

  defp validate_native_model(acc, config) do
    case native_model_config(config) do
      {:ok, _model} -> acc
      {:error, message} -> add_error(acc, message)
    end
  end

  # A camera builds its detect branch from `plugin:` alone, but only a
  # profile says which model the branch runs on. Unprofiled, it detects on
  # whatever model another camera loaded, or on none.
  defp validate_camera_profiles(acc, config) do
    config.cameras
    |> Enum.filter(&(&1.plugin != nil))
    |> Enum.reject(&profile_for(config, &1))
    |> Enum.reduce(acc, &add_error(&2, unprofiled_camera(&1)))
  end

  defp unprofiled_camera(%Camera{plugin: {:group, name}} = cam) do
    "camera #{cam.id}: detection resolves no profile — its model comes from plugin " <>
      "#{name}'s profile:, and that group has none in effect. Add a profile: to plugin #{name}"
  end

  defp unprofiled_camera(%Camera{} = cam) do
    "camera #{cam.id}: detection resolves no profile — the camera detects in this node's " <>
      "own engine and takes its model from a plugin group's profile:; name such a group " <>
      "as this camera's plugin:"
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
    |> validate_trackers(config)
    |> validate_reid_requires_bbd(config)
    |> warn_superseded_flags(config)
    |> warn_reid_without_bbd_stage(config)
  end

  # Every place a core can be named, refused at load: `Config.tracker/2`
  # fetches from the menu, so an unknown name would otherwise surface as a
  # pipeline that raises when the camera it belongs to starts streaming — long
  # after the operator who typed it stopped looking.
  defp validate_trackers(acc, config) do
    named =
      [{"tracking.tracker", config.tracker}] ++
        for(cam <- config.cameras, do: {"camera #{cam.id}: tracker", cam.tracker}) ++
        for(
          {name, profile} <- config.profiles,
          do: {"profile #{name}: tracking.tracker", profile.tracker}
        )

    Enum.reduce(named, acc, fn
      {_where, nil}, acc ->
        acc

      {where, name}, acc ->
        check(
          acc,
          Map.has_key?(@trackers, name),
          "#{where}: unknown tracker #{inspect(name)} (#{Enum.join(tracker_names(), ", ")})"
        )
    end)
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
    # "Unprofiled" here is a camera on a group whose profile did not resolve
    # (that is already its own load error; this avoids piling on a
    # misleading one). A camera with no plugin at all runs no tracker and
    # holds no opinion.
    unprofiled? =
      Enum.any?(config.cameras, fn
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
