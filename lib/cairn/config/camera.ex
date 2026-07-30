defmodule Cairn.Config.Camera do
  @moduledoc """
  Per-camera configuration parsed from the `cameras:` list in the YAML file.

  `min_score` is a map of label => minimum detection score, with a
  `"default"` key applied to labels not listed. It is the **wire floor**: it
  reaches the plugin subprocess as argv, the plugin drops everything below it,
  and changing it restarts the camera.

  `track` and `record` are the two host-side tiers layered on that floor —
  which detections earn a database row, and which earn video. Each is a
  per-label map of rules (`%{min_score: float}`) or `nil` when the block is
  absent. Absent means today's behaviour: everything above `min_score`
  qualifies. In a *present* tier a label with no rule of its own and no
  `"default"` rule is excluded from that tier — which is why, unlike
  `min_score`, no `"default"` is invented here. `Cairn.Config.tier_threshold/3`
  is where that distinction is spelled out; nothing else should re-derive it.

  The window seconds, `max_unseen_ms`, `max_live_tracks` and
  `stationary_after_ms` are overrides:
  `nil` means "use the global value" (`Cairn.Config.policy/2` resolves them).

  `plugin` selects the inference plugin (absent = no detection for this
  camera) and resolves to `nil | {:inline, argv} | {:group, name}`. A string
  without whitespace is a reference to a named group in the top-level
  `plugins:` map — an undefined name is a config error, not a command. A
  string with whitespace or an argv list is an inline per-camera command; the
  list form is the escape hatch for an inline command that takes no flags.

  Group references leave `parse/3` as `{:pending, name}` and are resolved
  against the parsed `plugins:` map by `Cairn.Config`.
  """

  alias Cairn.Config

  @known_keys ~w(id rtsp_url plugin min_score track record extra_ffmpeg_args transcode retention
                 pre_window_seconds post_window_seconds max_event_seconds max_unseen_ms
                 max_live_tracks stationary_after_ms)

  @default_min_score %{"default" => 0.5}

  defstruct id: nil,
            rtsp_url: nil,
            plugin: nil,
            min_score: @default_min_score,
            track: nil,
            record: nil,
            extra_ffmpeg_args: [],
            transcode: false,
            retention_days: nil,
            retention_per_label: %{},
            pre_window_seconds: nil,
            post_window_seconds: nil,
            max_event_seconds: nil,
            max_unseen_ms: nil,
            max_live_tracks: nil,
            stationary_after_ms: nil

  @type t :: %__MODULE__{}

  @typedoc """
  One parsed tier: label => rule. A rule is a map, not a bare number, so that
  per-label area, aspect and zone filters can join `:min_score` inside it later
  without changing the config shape; `:min_score` is the only key today.
  """
  @type tier :: %{optional(String.t()) => %{min_score: float()}}

  @doc false
  @spec parse(term(), non_neg_integer(), map()) :: {t() | nil, map()}
  def parse(raw, idx, acc) when is_map(raw) do
    acc = warn_unknown(acc, raw, @known_keys, "camera ##{idx}")
    id = Map.get(raw, "id")
    rtsp_url = Map.get(raw, "rtsp_url")

    cond do
      not (is_binary(id) and id =~ ~r/^[a-z0-9][a-z0-9_-]*$/) ->
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

  defp build(raw, id, rtsp_url, acc) do
    {min_score, acc} = parse_min_score(Map.get(raw, "min_score"), id, acc)
    {track, acc} = parse_tier(Map.get(raw, "track"), id, "track", acc)
    {record, acc} = parse_tier(Map.get(raw, "record"), id, "record", acc)
    {plugin, acc} = parse_plugin(Map.get(raw, "plugin"), id, acc)
    {extra_args, acc} = parse_extra_args(Map.get(raw, "extra_ffmpeg_args"), id, acc)

    cam = %__MODULE__{
      id: id,
      rtsp_url: rtsp_url,
      plugin: plugin,
      min_score: min_score,
      track: track,
      record: record,
      extra_ffmpeg_args: extra_args,
      transcode: Map.get(raw, "transcode", false) == true,
      retention_days: get_in(raw, ["retention", "days"]),
      retention_per_label: get_in(raw, ["retention", "per_label"]) || %{},
      pre_window_seconds: Map.get(raw, "pre_window_seconds"),
      post_window_seconds: Map.get(raw, "post_window_seconds"),
      max_event_seconds: Map.get(raw, "max_event_seconds"),
      max_unseen_ms: Map.get(raw, "max_unseen_ms"),
      max_live_tracks: Map.get(raw, "max_live_tracks"),
      stationary_after_ms: Map.get(raw, "stationary_after_ms")
    }

    {cam, acc}
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

  defp parse_plugin(nil, _id, acc), do: {nil, acc}

  defp parse_plugin(cmd, id, acc) when is_binary(cmd) do
    case String.split(cmd) do
      [name] -> {{:pending, name}, acc}
      [_ | _] = argv -> {{:inline, argv}, acc}
      [] -> {nil, invalid_plugin(acc, id)}
    end
  end

  defp parse_plugin(argv, id, acc) when is_list(argv) do
    if Enum.all?(argv, &is_binary/1) and argv != [] do
      {{:inline, argv}, acc}
    else
      {nil, invalid_plugin(acc, id)}
    end
  end

  defp parse_plugin(_other, id, acc), do: {nil, invalid_plugin(acc, id)}

  defp invalid_plugin(acc, id) do
    add_error(acc, "camera #{id}: plugin must be a plugin name, command string or argv list")
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
