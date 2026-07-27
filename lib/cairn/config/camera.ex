defmodule Cairn.Config.Camera do
  @moduledoc """
  Per-camera configuration parsed from the `cameras:` list in the YAML file.

  `min_score` is a map of label => minimum detection score, with a
  `"default"` key applied to labels not listed.

  The window seconds, `max_unseen_ms` and `max_live_tracks` are overrides:
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

  @known_keys ~w(id rtsp_url plugin min_score extra_ffmpeg_args transcode retention
                 pre_window_seconds post_window_seconds max_event_seconds max_unseen_ms
                 max_live_tracks)

  defstruct id: nil,
            rtsp_url: nil,
            plugin: nil,
            min_score: %{"default" => 0.5},
            extra_ffmpeg_args: [],
            transcode: false,
            retention_days: nil,
            retention_per_label: %{},
            pre_window_seconds: nil,
            post_window_seconds: nil,
            max_event_seconds: nil,
            max_unseen_ms: nil,
            max_live_tracks: nil

  @type t :: %__MODULE__{}

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
    {plugin, acc} = parse_plugin(Map.get(raw, "plugin"), id, acc)
    {extra_args, acc} = parse_extra_args(Map.get(raw, "extra_ffmpeg_args"), id, acc)

    cam = %__MODULE__{
      id: id,
      rtsp_url: rtsp_url,
      plugin: plugin,
      min_score: min_score,
      extra_ffmpeg_args: extra_args,
      transcode: Map.get(raw, "transcode", false) == true,
      retention_days: get_in(raw, ["retention", "days"]),
      retention_per_label: get_in(raw, ["retention", "per_label"]) || %{},
      pre_window_seconds: Map.get(raw, "pre_window_seconds"),
      post_window_seconds: Map.get(raw, "post_window_seconds"),
      max_event_seconds: Map.get(raw, "max_event_seconds"),
      max_unseen_ms: Map.get(raw, "max_unseen_ms"),
      max_live_tracks: Map.get(raw, "max_live_tracks")
    }

    {cam, acc}
  end

  defp parse_min_score(nil, _id, acc), do: {%{"default" => 0.5}, acc}

  defp parse_min_score(score, id, acc) when is_number(score) do
    validate_scores(%{"default" => score / 1}, id, acc)
  end

  defp parse_min_score(scores, id, acc) when is_map(scores) do
    scores
    |> Map.new(fn {label, score} -> {to_string(label), score} end)
    |> Map.put_new("default", 0.5)
    |> validate_scores(id, acc)
  end

  defp parse_min_score(_other, id, acc) do
    {%{"default" => 0.5}, add_error(acc, "camera #{id}: min_score must be a number or map")}
  end

  defp validate_scores(scores, id, acc) do
    bad = for {label, s} <- scores, not (is_number(s) and s >= 0 and s <= 1), do: label

    case bad do
      [] ->
        {Map.new(scores, fn {label, s} -> {label, s / 1} end), acc}

      labels ->
        {scores,
         add_error(
           acc,
           "camera #{id}: min_score values must be 0..1 (#{Enum.join(labels, ", ")})"
         )}
    end
  end

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
