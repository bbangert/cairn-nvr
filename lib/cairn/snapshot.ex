defmodule Cairn.Snapshot do
  @moduledoc """
  Per-event snapshot as `snapshots/{event_id}.jpg`, extracted async
  post-finalize. Failure is non-fatal — the UI falls back to a placeholder —
  but it is never silent: every attempt ends in exactly one
  `:event_snapshot_ready` or `:event_snapshot_failed` broadcast
  (`Cairn.EventArtifact`), so a consumer knows whether to fetch or to give up.

  When the event carries a `trigger` (the highest-scoring detection, captured
  by `Cairn.DetectionAggregator`), the frame is cut from that detection's
  moment in the clip and its bounding box + label are drawn on top — a
  Frigate-style "why did this record" thumbnail. The seek lands on the nearest
  keyframe (fast `-ss`), so on a long GOP the box can be a beat off the exact
  detection frame; close enough for a thumbnail. Without a trigger (old events)
  it falls back to the first frame, no box.
  """

  require Logger

  alias Cairn.{Config, DataDir, EventArtifact, Events, TrackPath}

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
    # Structural "exactly one frame per attempt": every step that can raise or
    # exit is inside `capture/2` or `record/2`, and the broadcast is the last
    # thing that happens — so a failure can never contradict a frame already
    # on the wire, and cannot swallow the frame either.
    case capture(row, config) do
      {:ok, out, size} ->
        case record(row, out) do
          :ok -> ready(row, out, size)
          {:error, reason} -> failed(row, reason)
        end

      {:error, reason} ->
        failed(row, reason)
    end

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

  @doc """
  Clip time (seconds) to cut the snapshot from — the trigger's moment, clamped
  inside the clip — or nil when the event carries no usable trigger. Public for
  tests.

  Two ways to place that moment, in preference order.

  The sidecar header's anchor, through `Cairn.TrackPath.anchor_clip_ms/2`,
  places it from media the writer actually held — its live half for choice, its
  drain half otherwise. That is the same function the browser overlay mirrors,
  so a poster frame cut this way lands on the frame the overlay draws its boxes
  over.

  Both of them, and the number handed to `-ss` below, are positions on the
  clip's *media* timeline counted from its first sample. They agree because the
  clip has no leading empty edit to disagree over — which is a property
  `Cairn.EventExtractor` maintains by starting every clip on a keyframe, not
  something any reader here checks.

  Failing that, `pre_window(config, camera)` — the *configured* pre-roll, not
  the retained one. That is an approximation, and the retained head falls short
  of the configured one for two separate reasons: a ring that had not filled
  yet, and `Cairn.EventExtractor` cutting the pre-roll back to its first
  keyframe (up to one GOP on a camera whose GOP outlives its fragments). The
  clamp is what keeps the error inside the clip. On a camera with a full ring
  and keyframe-aligned fragments the two agree to within tens of milliseconds;
  otherwise they disagree by however much pre-roll was not retained, which is a
  second or more.

  The sidecar is never *required*: it is allowed to be absent (no boxes, a
  failed write, a clip older than the feature), allowed to be corrupt, and
  allowed to carry a nil anchor, and a poster frame must render anyway. Every
  one of those falls back to the pre-window estimate rather than failing.
  """
  @spec clip_seek(Events.Event.t(), Config.t()) :: number() | nil
  def clip_seek(row, config) do
    case trigger(row) do
      nil ->
        nil

      trig ->
        raw = anchored_seek(row, trig) || pre_window(config, row.camera_id) + trigger_t(trig)

        case probe_duration(row.path) do
          {:ok, dur} when dur > 0 -> min(raw, max(dur - 0.2, 0.0))
          _ -> raw
        end
    end
  end

  # -- internals --------------------------------------------------------------

  # ffmpeg and the file it may or may not have written. `rescue`/`catch` both:
  # a raise (a bad argv, an unreadable dir) and an exit (a port that dies under
  # us) must still end in a frame.
  defp capture(row, config) do
    out = Path.join(DataDir.snapshots_dir(config.data_dir), "#{row.id}.jpg")

    {output, status} =
      System.cmd("ffmpeg", args(row, out, clip_seek(row, config)), stderr_to_stdout: true)

    # ffmpeg exits 0 even when a seek lands past the end and writes nothing, so
    # trust the file, not the exit code — a bogus snapshot_path 404s the UI.
    case File.stat(out) do
      {:ok, %{size: size}} when size > 0 ->
        {:ok, out, size}

      _ ->
        Logger.warning(
          "event #{row.id}: snapshot produced no output (ffmpeg #{status}): " <>
            String.slice(output, 0, 200)
        )

        {:error, :no_output}
    end
  rescue
    e ->
      Logger.warning("event #{row.id}: snapshot error: #{Exception.message(e)}")
      {:error, :exception}
  catch
    :exit, reason ->
      Logger.warning("event #{row.id}: snapshot exited: #{inspect(reason)}")
      {:error, :exception}
  end

  # The row update, not the file write, is what makes the jpg reachable
  # (`snapshot_url`), so `ready` follows it. The event can have gone away
  # while ffmpeg ran — retention deleted it, the recording was reconciled —
  # and that used to be swallowed whole. Ecto is the other half of the reason
  # for the `catch`: a pool checkout timeout surfaces as an exit, not a raise,
  # and `rescue` alone would let the task die with nothing announced.
  defp record(row, out) do
    case Events.set_snapshot(row.id, out) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("event #{row.id}: snapshot not recorded: #{inspect(reason)}")
        {:error, snapshot_reason(reason)}
    end
  rescue
    e ->
      Logger.warning("event #{row.id}: snapshot not recorded: #{Exception.message(e)}")
      {:error, :exception}
  catch
    :exit, reason ->
      Logger.warning("event #{row.id}: snapshot record exited: #{inspect(reason)}")
      {:error, :exception}
  end

  defp ready(row, out, size) do
    EventArtifact.broadcast(:event_snapshot_ready, %EventArtifact{
      event_id: row.id,
      camera_id: row.camera_id,
      path: out,
      bytes: size
    })
  end

  defp failed(row, reason) do
    EventArtifact.broadcast(:event_snapshot_failed, %EventArtifact{
      event_id: row.id,
      camera_id: row.camera_id,
      reason: reason
    })
  end

  defp snapshot_reason(:not_found), do: :not_found
  defp snapshot_reason(_other), do: :index_write_failed

  # nil on every miss, which is the whole contract with `clip_seek/2` above:
  # no clip path, no sidecar next to it, or bytes that are not a sidecar. The
  # anchor's own misses — no anchor, a half missing a field it needs, a result
  # before the start of the clip (a mismatched sidecar, or a trigger from
  # before the media the anchor pairs) — are `anchor_clip_ms/2`'s `:error`,
  # decided there so this and the browser overlay cannot drift apart on which
  # anchor answers. A negative seek is worse than the estimate it would
  # replace, so it is a miss there rather than something clamped to zero here.
  defp anchored_seek(%{path: path}, trig) when is_binary(path) do
    with {:ok, bytes} <- File.read(DataDir.trackpath_for_clip(path)),
         {:ok, %{"anchor" => anchor}} <- TrackPath.decode(bytes),
         {:ok, clip_ms} <- TrackPath.anchor_clip_ms(anchor, trigger_t(trig) * 1000) do
      clip_ms / 1000
    else
      _miss -> nil
    end
  end

  defp anchored_seek(_row, _trig), do: nil

  # The trigger's offset into the event, in seconds. A JSON round-trip can put
  # anything in there; anything but a number is read as the event's own start.
  defp trigger_t(%{"t" => t}) when is_number(t), do: t
  defp trigger_t(_trig), do: 0.0

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
    # require a well-formed [x,y,w,h] numeric bbox — a malformed one would make
    # clamp_bbox raise; treat it as no trigger so the snapshot still falls back
    # to the first frame rather than producing nothing
    case t["bbox"] do
      [x, y, w, h] when is_number(x) and is_number(y) and is_number(w) and is_number(h) -> t
      _ -> nil
    end
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
