defmodule Cairn.Config.Camera do
  @moduledoc """
  Per-camera configuration parsed from the `cameras:` list in the YAML file.

  `min_score` is a map of label => minimum detection score, with a
  `"default"` key applied to labels not listed. It is the **wire floor**: it
  reaches the engine as the stream's params at session start, the engine
  drops everything below it, and changing it restarts the camera.

  `track` and `record` are the two host-side tiers layered on that floor —
  which detections earn a database row, and which earn video. Each is a
  per-label map of rules (`%{min_score: float}`) or `nil` when the block is
  absent. Absent means today's behaviour: everything above `min_score`
  qualifies. In a *present* tier a label with no rule of its own and no
  `"default"` rule is excluded from that tier — which is why, unlike
  `min_score`, no `"default"` is invented here. `Cairn.Config.tier_threshold/3`
  is where that distinction is spelled out; nothing else should re-derive it.

  The window seconds, `max_unseen_ms`, `max_live_tracks`,
  `stationary_after_ms` and `tracker` are overrides: `nil` means "use the
  profile's, else the global value" (`Cairn.Config.policy/2` resolves the
  bounds, `Cairn.Config.tracker/2` the core). `tracker` names one of the cores
  `Membrane.MOTTracker` can host; an unknown name is a load-time error.

  `substream_url` is the camera's second, low-resolution stream: detection
  runs on it while recording keeps cutting from the main stream. It is
  always RTSP-native whatever `ingest` says — with `ingest: ffmpeg` the
  bridge owns main and the source element runs sub-only. Both streams must
  share an **aspect ratio**: detections are normalized against the frame
  that produced them and are drawn on artifacts cut from the main ring, so a
  sub framed differently puts every box in the wrong place.

  `plugin` selects the camera's detection (absent = none) and resolves to
  `nil | {:group, name}`: a reference to a named entry in the top-level
  `plugins:` map, whose `profile:` is what picks the model the in-VM engine
  runs. An undefined name is a config error. The inline-command form died
  with the external plugin path (membrane port phase 6) and is refused with
  its remedy spelled out.

  Group references leave `parse/3` as `{:pending, name}` and are resolved
  against the parsed `plugins:` map by `Cairn.Config`.
  """

  alias Cairn.Config

  @known_keys ~w(id rtsp_url substream_url plugin pipeline ingest min_score track record
                 extra_ffmpeg_args transcode retention pre_window_seconds post_window_seconds
                 max_event_seconds max_unseen_ms max_live_tracks stationary_after_ms tracker
                 motion_json annotation_offset_ms zones)

  # Wider than any plausible stream lag; the bound exists so a typo (seconds
  # written as ms, or a stray zero) is an error naming itself rather than
  # annotations silently landing outside every clip.
  @max_annotation_offset_ms 30_000

  @default_min_score %{"default" => 0.5}

  defstruct id: nil,
            rtsp_url: nil,
            substream_url: nil,
            plugin: nil,
            min_score: @default_min_score,
            track: nil,
            record: nil,
            extra_ffmpeg_args: [],
            transcode: false,
            ingest: :ffmpeg,
            retention_days: nil,
            retention_per_label: %{},
            pre_window_seconds: nil,
            post_window_seconds: nil,
            max_event_seconds: nil,
            max_unseen_ms: nil,
            max_live_tracks: nil,
            stationary_after_ms: nil,
            tracker: nil,
            # The motion gate's scene config, verbatim JSON — the operator's
            # knob (D-P6: a profile never writes it) holding THIS scene's gate
            # settings: its grid, its thresholds, whether it runs at all. The
            # gate's own knobs, unrelated to the presence zones in `zones:`.
            # Validated at load, carried to the detect branch's gate element as
            # `stream_params.motion_json`. Tier-2 groups reject it (D-S4,
            # `Cairn.Config.validate/2`).
            motion_json: nil,
            # Signed ms, applied where annotations are RENDERED and never baked
            # into what is stored — see `Cairn.Config.annotation_offset_ms/2`.
            annotation_offset_ms: 0,
            # `[Cairn.Zones.zone()]` — the polygons `Cairn.Pipeline.PresenceSink`
            # filters presence through. A camera field rather than its own store
            # so a zone edit is refresh-class: it is absent from
            # `Cairn.Config.Server`'s `@restart_fields`, so it reaches the sink
            # through the `{:policy, camera, _}` refresh and never restarts the
            # camera an operator is watching while they draw.
            zones: []

  @type t :: %__MODULE__{}

  @typedoc """
  One parsed tier: label => rule. A rule is a map, not a bare number, so that
  per-label area and aspect filters can join `:min_score` inside it later
  without changing the config shape; `:min_score` is the only key today.
  (Zone filtering did not land here: it is the camera-level `zones:` list,
  applied to every label alike by `Cairn.Pipeline.PresenceSink`.)
  """
  @type tier :: %{optional(String.t()) => %{min_score: float()}}

  @doc """
  Which of the camera's streams the detect branch is behind.

  The one derivation of "substream configured means detection moves to the
  sub" — the pipeline wiring, the owner's watchdog, and the camera tracker's
  epoch filter all resolve through here, so they cannot drift apart.
  """
  @spec detect_role(t()) :: :main | :sub
  def detect_role(%__MODULE__{substream_url: url}) when is_binary(url), do: :sub
  def detect_role(%__MODULE__{}), do: :main

  # Anchored (`\A`/`\z`, not `^`/`$`) so a trailing newline cannot sneak past
  # the last character class the way `$` allows. The class is exported because
  # three things must agree with it: `Cairn.Config`'s message attribution, the
  # row changeset in `Cairn.Cameras.Camera`, and zone ids in `Cairn.Zones`.
  @id_class "[a-z0-9][a-z0-9_-]*"
  @id_regex Regex.compile!("\\A#{@id_class}\\z")

  @doc false
  @spec id_class() :: String.t()
  def id_class, do: @id_class

  # The row-settings key space, taken by two callers: `Cairn.Cameras.raw_maps/0`
  # before rendering, so an unknown key never reaches the parser as a row's
  # fault, and `Cairn.ConfigSource.import_row/2` before storing, where the
  # drop is permanent.
  @spec known_keys() :: [String.t()]
  def known_keys, do: @known_keys

  defp valid_id?(id), do: is_binary(id) and id =~ @id_regex

  @doc false
  @spec parse(term(), non_neg_integer(), map()) :: {t() | nil, map()}
  def parse(raw, idx, acc) when is_map(raw) do
    id = Map.get(raw, "id")
    acc = warn_unknown_keys(acc, raw, id, idx)
    rtsp_url = Map.get(raw, "rtsp_url")

    cond do
      not valid_id?(id) ->
        {nil, add_error(acc, "camera ##{idx}: id is required ([a-z0-9_-], lowercase)")}

      not is_binary(rtsp_url) or rtsp_url == "" ->
        {nil, add_error(acc, "camera #{id}: rtsp_url is required")}

      true ->
        build(raw, id, rtsp_url, acc)
    end
  end

  def parse(_raw, idx, acc) do
    {nil, add_error(acc, "camera ##{idx}: must be a mapping")}
  end

  # A valid id lets an unknown-key warning be attributed to it directly
  # (`Cairn.Config.partition_by_camera/1` reads that prefix); without one
  # there is no id yet to attribute to, so it keeps the index form.
  defp warn_unknown_keys(acc, raw, id, idx) do
    if valid_id?(id) do
      raw
      |> Map.keys()
      |> Enum.reject(&(&1 in @known_keys))
      |> Enum.reduce(acc, fn key, acc ->
        add_warning(acc, "camera #{id}: unknown key #{inspect(key)}")
      end)
    else
      warn_unknown(acc, raw, @known_keys, "camera ##{idx}")
    end
  end

  defp build(raw, id, rtsp_url, acc) do
    {min_score, acc} = parse_min_score(Map.get(raw, "min_score"), id, acc)
    {track, acc} = parse_tier(Map.get(raw, "track"), id, "track", acc)
    {record, acc} = parse_tier(Map.get(raw, "record"), id, "record", acc)
    {plugin, acc} = parse_plugin(Map.get(raw, "plugin"), id, acc)
    acc = check_pipeline(Map.get(raw, "pipeline"), id, acc)
    transcode = Map.get(raw, "transcode", false) == true

    {ingest, acc} =
      parse_ingest(Map.get(raw, "ingest"), id, acc, rtsp_url, transcode)

    {extra_args, acc} = parse_extra_args(Map.get(raw, "extra_ffmpeg_args"), id, acc)
    {substream_url, acc} = parse_substream(Map.get(raw, "substream_url"), id, acc)
    {motion_json, acc} = parse_motion_json(Map.get(raw, "motion_json"), id, acc)

    {annotation_offset_ms, acc} =
      parse_annotation_offset(Map.get(raw, "annotation_offset_ms"), id, acc)

    {zones, acc} = parse_zones(Map.get(raw, "zones"), id, acc)

    cam = %__MODULE__{
      id: id,
      rtsp_url: rtsp_url,
      substream_url: substream_url,
      plugin: plugin,
      min_score: min_score,
      track: track,
      record: record,
      extra_ffmpeg_args: extra_args,
      transcode: transcode,
      ingest: ingest,
      retention_days: get_in(raw, ["retention", "days"]),
      retention_per_label: get_in(raw, ["retention", "per_label"]) || %{},
      pre_window_seconds: Map.get(raw, "pre_window_seconds"),
      post_window_seconds: Map.get(raw, "post_window_seconds"),
      max_event_seconds: Map.get(raw, "max_event_seconds"),
      max_unseen_ms: Map.get(raw, "max_unseen_ms"),
      max_live_tracks: Map.get(raw, "max_live_tracks"),
      stationary_after_ms: Map.get(raw, "stationary_after_ms"),
      tracker: Map.get(raw, "tracker"),
      motion_json: motion_json,
      annotation_offset_ms: annotation_offset_ms,
      zones: zones
    }

    {cam, acc}
  end

  # A zone that fails validation takes the whole camera's list with it: a
  # partial fleet of polygons would filter presence somewhere the operator
  # never drew, which is worse than the load error they can read.
  defp parse_zones(nil, _id, acc), do: {[], acc}

  defp parse_zones(zones, id, acc) when is_list(zones) do
    # Taken ids come from every EARLIER entry, valid or not, so a duplicate
    # is reported even when its twin failed on some other rule — otherwise
    # fixing that rule would surface the duplicate one load later.
    {parsed, acc, _taken} =
      zones
      |> Enum.with_index()
      |> Enum.reduce({[], acc, []}, fn {raw, index}, {parsed, acc, taken} ->
        case Cairn.Zones.validate(raw, taken) do
          {:ok, zone} ->
            {[zone | parsed], acc, [zone.id | taken]}

          {:error, messages} ->
            {parsed, zone_errors(acc, id, zone_ref(raw, index), messages),
             taken ++ raw_zone_id(raw)}
        end
      end)

    if length(parsed) == length(zones), do: {Enum.reverse(parsed), acc}, else: {[], acc}
  end

  defp parse_zones(_other, id, acc),
    do: {[], add_error(acc, "camera #{id}: zones must be a list")}

  # The camera-id convention one level down: name the zone when it has a
  # usable id to be named by, and fall back to its position when it does not.
  defp zone_ref(raw, index) when is_map(raw) do
    case Map.get(raw, "id") || Map.get(raw, :id) do
      id when is_binary(id) -> if valid_id?(id), do: id, else: "##{index}"
      _other -> "##{index}"
    end
  end

  defp zone_ref(_raw, index), do: "##{index}"

  defp zone_errors(acc, id, ref, messages) do
    Enum.reduce(messages, acc, fn message, acc ->
      add_error(acc, "camera #{id}: zone #{ref}: #{message}")
    end)
  end

  defp raw_zone_id(raw) when is_map(raw) do
    case Map.get(raw, "id") || Map.get(raw, :id) do
      id when is_binary(id) -> [id]
      _other -> []
    end
  end

  defp raw_zone_id(_raw), do: []

  # Integer ms only, and signed: the correction runs either way depending on
  # which of the two streams is behind. Absent is 0, which every consumer
  # treats as identity — an unset offset must cost nothing and change nothing.
  defp parse_annotation_offset(nil, _id, acc), do: {0, acc}

  defp parse_annotation_offset(ms, _id, acc)
       when is_integer(ms) and abs(ms) <= @max_annotation_offset_ms,
       do: {ms, acc}

  defp parse_annotation_offset(ms, id, acc) when is_integer(ms) do
    {0,
     add_error(
       acc,
       "camera #{id}: annotation_offset_ms must be within " <>
         "±#{@max_annotation_offset_ms} ms (got #{ms})"
     )}
  end

  defp parse_annotation_offset(_other, id, acc) do
    {0, add_error(acc, "camera #{id}: annotation_offset_ms must be an integer number of ms")}
  end

  # Validated here rather than at pipeline build, where the same string
  # raises inside `Cairn.Pipeline.Camera.motion_gate/3` as a crash-looping
  # camera instead of a config error naming the problem. The string is
  # carried VERBATIM on success — the gate resolves it again itself, so
  # nothing here can drift from what the element actually reads.
  defp parse_motion_json(nil, _id, acc), do: {nil, acc}

  defp parse_motion_json(json, id, acc) when is_binary(json) do
    case Cairn.Motion.Config.resolve_json(json) do
      {:ok, nil} ->
        # Valid vocabulary, no detector: `"enabled": true` was not said, so
        # the gate will not be built — indistinguishable at runtime from
        # omitting the key. Warned, not refused: the string is legal and
        # carried verbatim, but an operator who wrote a scene config surely
        # meant it to gate something (the silent-fallback lesson).
        {json,
         add_warning(
           acc,
           ~s(camera #{id}: motion_json resolves to no detector, so the gate is never ) <>
             ~s(built — add "enabled": true to it)
         )}

      {:ok, _resolved} ->
        {json, acc}

      {:error, message} ->
        {nil, add_error(acc, "camera #{id}: motion_json: #{message}")}
    end
  end

  defp parse_motion_json(_other, id, acc) do
    {nil, add_error(acc, "camera #{id}: motion_json must be a JSON string")}
  end

  defp parse_min_score(nil, _id, acc), do: {@default_min_score, acc}

  # A bare number is the block's `"default"`; routing it through the map clause
  # keeps one validation path and one error message.
  defp parse_min_score(score, id, acc) when is_number(score) do
    parse_min_score(%{"default" => score}, id, acc)
  end

  defp parse_min_score(scores, id, acc) when is_map(scores) do
    case label_rules(scores, &min_score_rule/1) do
      {:ok, rules} ->
        # A catch-all is invented here and nowhere else: without one, a label
        # the operator did not list would have no wire floor at all.
        {Map.merge(@default_min_score, rules), acc}

      {:error, labels} ->
        {@default_min_score,
         add_error(
           acc,
           "camera #{id}: min_score values must be 0..1 (#{Enum.join(labels, ", ")})"
         )}
    end
  end

  defp parse_min_score(_other, id, acc) do
    {@default_min_score, add_error(acc, "camera #{id}: min_score must be a number or map")}
  end

  # The `track:` / `record:` tiers. Unlike `min_score`: an absent block is
  # `nil` rather than a default map; the block itself must be a mapping (a bare
  # number would have to mean "default", and an accidental catch-all is what
  # these tiers exist to avoid); each rule is a map rather than a bare score;
  # and no `"default"` is injected — see the moduledoc on why an absent default
  # has to keep meaning "nothing else qualifies".
  defp parse_tier(nil, _id, _key, acc), do: {nil, acc}

  defp parse_tier(block, id, key, acc) when is_map(block) do
    case label_rules(block, &tier_rule/1) do
      {:ok, rules} ->
        {rules, acc}

      {:error, labels} ->
        {nil,
         add_error(
           acc,
           "camera #{id}: #{key} values must be a number or a map of {min_score: 0..1} " <>
             "(#{Enum.join(labels, ", ")})"
         )}
    end
  end

  defp parse_tier(_other, id, key, acc) do
    {nil, add_error(acc, "camera #{id}: #{key} must be a mapping of label to threshold")}
  end

  # Shared by `min_score` and both tiers: stringify every label, run `extract`
  # over every value, and name every label that failed in a single error. What
  # differs between the callers — what `extract` accepts, the shape of a parsed
  # rule, and what happens to a missing `"default"` — stays in the wrappers.
  defp label_rules(block, extract) do
    parsed = Map.new(block, fn {label, value} -> {to_string(label), extract.(value)} end)

    case Enum.sort(for {label, :error} <- parsed, do: label) do
      [] -> {:ok, Map.new(parsed, fn {label, {:ok, rule}} -> {label, rule} end)}
      labels -> {:error, labels}
    end
  end

  defp min_score_rule(score) when is_number(score) and score >= 0 and score <= 1,
    do: {:ok, score / 1}

  defp min_score_rule(_other), do: :error

  # A bare number is sugar for the map form, which is where per-label filters
  # beyond a score will be added.
  defp tier_rule(score) when is_number(score), do: tier_rule(%{"min_score" => score})

  defp tier_rule(rule) when is_map(rule) do
    # Unknown keys are an error rather than the warning unknown keys get
    # elsewhere: a filter this file does not implement yet must not look
    # applied. The set grows as the filters land.
    case Map.new(rule, fn {key, value} -> {to_string(key), value} end) do
      %{"min_score" => score} = normalized when map_size(normalized) == 1 ->
        case min_score_rule(score) do
          {:ok, score} -> {:ok, %{min_score: score}}
          :error -> :error
        end

      _other ->
        :error
    end
  end

  defp tier_rule(_other), do: :error

  # `pipeline:` stopped selecting anything when the classic path was deleted
  # (membrane port phase 6). `membrane` is tolerated so a migrated fleet's
  # config keeps loading; `classic` is refused with the removal spelled out
  # rather than warned as an unknown key, because a camera that asked for it
  # would otherwise silently run a different stack than its file says.
  defp check_pipeline(nil, _id, acc), do: acc
  defp check_pipeline("membrane", _id, acc), do: acc

  defp check_pipeline("classic", id, acc) do
    add_error(
      acc,
      "camera #{id}: the classic pipeline was removed (membrane port phase 6) — every " <>
        "camera runs the membrane pipeline now; delete the pipeline: key"
    )
  end

  defp check_pipeline(_other, id, acc) do
    add_error(acc, "camera #{id}: pipeline is \"membrane\" or absent — the key is vestigial")
  end

  # RTSP-native ingest has real preconditions, each refused at load where the
  # operator reads diagnostics: the `rtsp` library rejects non-rtsp://
  # schemes outright (an FLV camera keeps the ffmpeg bridge — D-M7's
  # per-camera escape hatch), and transcode happens inside ffmpeg, which
  # this ingest removes from the chain entirely.
  defp parse_ingest(nil, _id, acc, _url, _transcode), do: {:ffmpeg, acc}
  defp parse_ingest("ffmpeg", _id, acc, _url, _transcode), do: {:ffmpeg, acc}

  defp parse_ingest("rtsp", id, acc, url, transcode) do
    cond do
      not (is_binary(url) and String.starts_with?(url, "rtsp://")) ->
        {:ffmpeg, add_error(acc, "camera #{id}: ingest \"rtsp\" requires an rtsp:// url")}

      transcode ->
        {:ffmpeg,
         add_error(
           acc,
           "camera #{id}: ingest \"rtsp\" cannot transcode — transcode rides the ffmpeg bridge"
         )}

      true ->
        {:rtsp, acc}
    end
  end

  defp parse_ingest(_other, id, acc, _url, _transcode) do
    {:ffmpeg, add_error(acc, "camera #{id}: ingest must be \"rtsp\" or \"ffmpeg\"")}
  end

  # No scheme escape hatch here, unlike `rtsp_url`: the sub stream is read by
  # the RTSP source element whatever `ingest` the main stream uses, and that
  # element's library rejects every other scheme outright.
  defp parse_substream(nil, _id, acc), do: {nil, acc}

  defp parse_substream(url, id, acc) when is_binary(url) do
    if String.starts_with?(url, "rtsp://"),
      do: {url, acc},
      else: {nil, substream_error(acc, id)}
  end

  defp parse_substream(_other, id, acc), do: {nil, substream_error(acc, id)}

  defp substream_error(acc, id) do
    add_error(acc, "camera #{id}: substream_url must be an rtsp:// url")
  end

  defp parse_plugin(nil, _id, acc), do: {nil, acc}

  defp parse_plugin(cmd, id, acc) when is_binary(cmd) do
    case String.split(cmd) do
      [name] -> {{:pending, name}, acc}
      [_ | _] -> {nil, inline_plugin(acc, id)}
      [] -> {nil, invalid_plugin(acc, id)}
    end
  end

  defp parse_plugin(argv, id, acc) when is_list(argv) and argv != [],
    do: {nil, inline_plugin(acc, id)}

  defp parse_plugin(_other, id, acc), do: {nil, invalid_plugin(acc, id)}

  defp inline_plugin(acc, id) do
    add_error(
      acc,
      "camera #{id}: inline plugin commands were removed with the external plugin path " <>
        "(membrane port phase 6) — detection runs in this node's own engine; name a " <>
        "plugins: group whose profile: picks the model"
    )
  end

  defp invalid_plugin(acc, id) do
    add_error(acc, "camera #{id}: plugin must be a plugin group name")
  end

  defp parse_extra_args(nil, _id, acc), do: {[], acc}

  defp parse_extra_args(args, id, acc) when is_list(args) do
    if Enum.all?(args, &is_binary/1) do
      {args, acc}
    else
      {[], add_error(acc, "camera #{id}: extra_ffmpeg_args must be a list of strings")}
    end
  end

  defp parse_extra_args(args, _id, acc) when is_binary(args), do: {String.split(args), acc}

  defp parse_extra_args(_other, id, acc) do
    {[], add_warning(acc, "camera #{id}: ignoring invalid extra_ffmpeg_args")}
  end

  defp add_error(acc, msg), do: Config.add_error(acc, msg)
  defp add_warning(acc, msg), do: Config.add_warning(acc, msg)
  defp warn_unknown(acc, map, known, where), do: Config.warn_unknown(acc, map, known, where)
end
