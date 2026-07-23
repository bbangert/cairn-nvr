defmodule Cairn.Snapshot do
  @moduledoc """
  Per-event snapshot as `snapshots/{event_id}.jpg`, extracted async
  post-finalize. Failure is non-fatal (log only) — the UI falls back to a
  placeholder.

  When the event carries a `trigger` (the highest-scoring detection, captured
  by `Cairn.DetectionAggregator`), the frame is cut from that detection's
  moment in the clip and its bounding box + label are drawn on top — a
  Frigate-style "why did this record" thumbnail. The seek lands on the nearest
  keyframe (fast `-ss`), so on a long GOP the box can be a beat off the exact
  detection frame; close enough for a thumbnail. Without a trigger (old events)
  it falls back to the first frame, no box.
  """

  require Logger

  alias Cairn.{Config, DataDir, Events}

  # tuned for HD+ camera frames; fontsize is not an ffmpeg expression so it
  # can't scale with resolution — a fixed size reads fine from ~640p up.
  @box_color "lime"
  @thickness 6
  @fontsize 40
  @default_font "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"

  @spec take_async(Events.Event.t(), Config.t()) :: {:ok, pid()}
  def take_async(row, config) do
    Task.Supervisor.start_child(Cairn.TaskSupervisor, fn -> take(row, config) end)
  end

  @spec take(Events.Event.t(), Config.t()) :: :ok
  def take(row, config) do
    out = Path.join(DataDir.snapshots_dir(config.data_dir), "#{row.id}.jpg")

    {output, status} =
      System.cmd("ffmpeg", args(row, out, clip_seek(row, config)), stderr_to_stdout: true)

    # ffmpeg exits 0 even when a seek lands past the end and writes nothing, so
    # trust the file, not the exit code — a bogus snapshot_path 404s the UI.
    if File.exists?(out) and File.stat!(out).size > 0 do
      Events.set_snapshot(row.id, out)
    else
      Logger.warning(
        "event #{row.id}: snapshot produced no output (ffmpeg #{status}): " <>
          String.slice(output, 0, 200)
      )
    end

    :ok
  rescue
    e ->
      Logger.warning("event #{row.id}: snapshot error: #{Exception.message(e)}")
      :ok
  end

  @doc """
  ffmpeg argv for the snapshot. `seek` is the clip time (seconds) to cut from,
  or nil for the first frame with no overlay. Public for tests.
  """
  @spec args(Events.Event.t(), Path.t(), number() | nil) :: [String.t()]
  def args(row, out, seek) do
    base = ["-y", "-hide_banner", "-loglevel", "error"]
    frame = ~w(-frames:v 1 -q:v 4)

    case {seek, trigger(row)} do
      {seek, trig} when is_number(seek) and is_map(trig) ->
        base ++
          ["-ss", fmt(seek), "-i", row.path] ++
          frame ++ ["-vf", overlay(trig)] ++ [out]

      _ ->
        base ++ ["-i", row.path] ++ frame ++ [out]
    end
  end

  # -- internals --------------------------------------------------------------

  # Clip time to cut the snapshot from: the trigger's moment (pre-roll + its
  # offset), clamped inside the clip. A freshly-started camera has less than a
  # full pre-window of pre-roll, so the raw offset can run past a short clip.
  defp clip_seek(row, config) do
    case trigger(row) do
      nil ->
        nil

      trig ->
        raw = pre_window(config, row.camera_id) + (trig["t"] || 0.0)

        case probe_duration(row.path) do
          {:ok, dur} when dur > 0 -> min(raw, max(dur - 0.2, 0.0))
          _ -> raw
        end
    end
  end

  defp probe_duration(path) do
    case System.cmd("ffprobe", ~w(-v error -show_entries format=duration -of csv=p=0) ++ [path],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        case Float.parse(String.trim(out)) do
          {dur, _} -> {:ok, dur}
          :error -> :error
        end

      _ ->
        :error
    end
  end

  # The row can arrive two ways: straight off `Events.finalize` (the extractor's
  # snapshot path), where Repo returns the struct as-set and the trigger map
  # still has atom keys, or re-read from the DB (JSON round-trip) with string
  # keys. Normalize to string keys so both work.
  defp trigger(%{labels: %{"trigger" => t}}) when is_map(t) do
    t = Map.new(t, fn {k, v} -> {to_string(k), v} end)
    if is_list(t["bbox"]), do: t, else: nil
  end

  defp trigger(_), do: nil

  defp overlay(trig) do
    {x, y, w, h} = clamp_bbox(trig["bbox"])

    box =
      "drawbox=x=iw*#{fmt(x)}:y=ih*#{fmt(y)}:w=iw*#{fmt(w)}:h=ih*#{fmt(h)}" <>
        ":color=#{@box_color}:t=#{@thickness}"

    case label(trig, x, y) do
      nil -> box
      text -> box <> "," <> text
    end
  end

  defp label(trig, x, y) do
    font = Application.get_env(:cairn, :snapshot_font, @default_font)

    if File.exists?(font) do
      text = "#{sanitize(trig["label"])} #{fmt(round2(trig["score"]))}"

      # text= MUST precede fontfile= — `fontfile=<path>:text=` makes ffmpeg's
      # parser swallow the separator. drawtext frame dims are W/H (iw/ih are
      # drawbox-only); the escaped `\,` keeps the comma inside max().
      "drawtext=text='#{text}':fontfile=#{font}" <>
        ":x=W*#{fmt(x)}:y=max(H*#{fmt(y)}-th-#{@thickness}\\,0)" <>
        ":fontsize=#{@fontsize}:fontcolor=black:box=1:boxcolor=#{@box_color}:boxborderw=6"
    end
  end

  # bbox is [x, y, w, h] normalized; keep it inside the frame and non-degenerate
  defp clamp_bbox([x, y, w, h]) do
    x = clamp01(x)
    y = clamp01(y)
    {x, y, max(min(w, 1.0 - x), 0.0), max(min(h, 1.0 - y), 0.0)}
  end

  defp clamp01(v) when is_number(v), do: v |> max(0.0) |> min(1.0)
  defp clamp01(_), do: 0.0

  defp pre_window(config, camera_id) do
    case Enum.find(config.cameras, &(&1.id == camera_id)) do
      nil -> config.pre_window_seconds
      cam -> Config.windows(config, cam).pre
    end
  end

  # coco labels are [a-z ] already; strip anything else so it can't break the
  # filtergraph (commas/colons/quotes) and cap the length
  defp sanitize(label) when is_binary(label) do
    label |> String.replace(~r/[^\w \-]/, "") |> String.slice(0, 24)
  end

  defp sanitize(_), do: ""

  defp round2(n) when is_number(n), do: Float.round(n / 1, 2)
  defp round2(_), do: 0.0

  defp fmt(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 4)
  defp fmt(n), do: to_string(n)
end
