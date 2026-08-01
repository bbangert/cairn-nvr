defmodule Cairn.EventExtractor do
  @moduledoc """
  One `:temporary` process per active event, streaming fragments to a
  single mp4 on disk and writing the track-path sidecar that goes beside it.

  On start: inserts the `active` index row, opens
  `events/{camera}/{event_id}_{camera}_{ts}.mp4`, writes the init segment,
  then atomically drains the ring's pre-window and subscribes for live
  fragments (`Cairn.RingBuffer.drain_and_subscribe/3` — race-free
  boundary). Those drained fragments are the only sight anyone gets of the
  clip's own time-zero, so the anchor taken there (`anchor/3`) pairs it with a
  wall clock for the sidecar header; it would otherwise be discarded with the
  fragments. The first fragment to arrive *live* completes that anchor with a
  second, tighter pairing (`note_live_fragment/2`) — the one a reader prefers,
  and the reason `Cairn.TrackPath` documents two.

  The media path holds nothing: a fragment is written as it arrives and let
  go, with a datasync roughly every 2s of media, so the clip's own length
  costs no memory. The box buffer is the exception — `Cairn.DetectionAggregator`
  casts every tagged box of the open event here, and that list grows with the
  event until `@max_path_entries` stops it. It is transient heap in a process
  that exists only for this event.

  Finalize: closes the file, updates the row (`finalized`, ended_at,
  bytes, labels, max_score), writes the sidecar, broadcasts
  `:event_clip_ready` with the post-remux size (or `:event_clip_failed`),
  kicks off the async snapshot, emits `[:cairn, :extractor, :finalized]`
  telemetry, exits `:normal`. Only a clip the index accepted gets a sidecar,
  and failing to write one never changes what the event is announced as. A
  crash *while recording* leaves the row `active` and announces no artifact at
  all; boot reconciliation marks it `partial`. A crash inside finalize is
  different: `:event_ended` has already been broadcast by then, so the failure
  is caught and announced as `:event_clip_failed` with `:exception` rather
  than leaving a consumer waiting for a frame that is never coming.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Cairn.{Config, DataDir, EventArtifact, Events, RingBuffer, TrackPath}

  @fsync_media_ms 2_000
  # Box entries, not batches, and global rather than per track: `max_live_tracks`
  # (128) bounds what is live at one instant, not how many distinct objects a
  # long event sees, so a per-track cap alone bounds nothing. At the maximum
  # `max_event_seconds` (86,400) this is what the buffer is actually held to;
  # 200k entries is tens of MB of transient heap. `Cairn.TrackPath` applies its
  # own per-track cap on top, after keyframe selection.
  #
  # The default only: `:max_path_entries` in the start opts overrides it, read
  # once into state at init so a test can reach the cap's boundary without
  # pushing 200k tuples through a real process.
  @max_path_entries 200_000

  def start_link(opts) do
    camera = Keyword.fetch!(opts, :camera)
    event = Keyword.fetch!(opts, :event)

    GenServer.start_link(__MODULE__, opts,
      name: Cairn.Registry.via(camera.id, {:extractor, event.id})
    )
  end

  @doc "Starts an extractor under `Cairn.EventSupervisor` (aggregator API)."
  @spec start(Cairn.Config.Camera.t(), Cairn.Event.t()) :: DynamicSupervisor.on_start_child()
  def start(camera, event) do
    DynamicSupervisor.start_child(
      Cairn.EventSupervisor,
      {__MODULE__, camera: camera, event: event}
    )
  end

  @doc "Tells the extractor to close the clip and exit normally."
  @spec finalize(pid() | nil, Cairn.Event.t()) :: :ok
  def finalize(nil, _event), do: :ok
  def finalize(pid, event), do: GenServer.cast(pid, {:finalize, event})

  # -- server -----------------------------------------------------------------

  @impl true
  def init(opts) do
    state = %{
      camera: Keyword.fetch!(opts, :camera),
      event: Keyword.fetch!(opts, :event),
      config: Keyword.get_lazy(opts, :config, &Config.Server.get/0),
      opts: opts,
      io: nil,
      path: nil,
      bytes: 0,
      fragments: 0,
      unsynced_media_ms: 0,
      started_ms: System.monotonic_time(:millisecond),
      # The dense box buffer the aggregator feeds, newest batch first: a cast
      # prepends and the flush reverses. `track_entries` counts boxes, not
      # batches, so the cap can be checked without walking the list.
      track_boxes: [],
      track_entries: 0,
      track_truncated: false,
      max_path_entries: Keyword.get(opts, :max_path_entries, @max_path_entries),
      # Built at the drain in `handle_continue(:open, ...)` — nil until then —
      # and completed with its live half by the first fragment to arrive after.
      anchor: nil
    }

    {:ok, state, {:continue, :open}}
  end

  @impl true
  def handle_continue(:open, state) do
    %{camera: camera, event: event, config: config} = state

    path =
      DataDir.event_clip_path(
        config.data_dir,
        camera.id,
        event.id,
        DateTime.to_unix(event.started_at)
      )

    File.mkdir_p!(Path.dirname(path))

    with {:ok, _row} <- Events.create_active(event, path),
         {:ok, io} <- File.open(path, [:write, :binary, :raw, :delayed_write]) do
      {:ok, %{init: init, fragments: drained}} =
        RingBuffer.drain_and_subscribe(camera.id, nil, self())

      # Read here and nowhere later: the drained fragments are in hand and none
      # of them has been written yet, so this is as close as a wall clock gets
      # to the end of the drained media. Close, not equal — ffmpeg is part-way
      # through a fragment it has not written out, and that fragment's content
      # was captured before this read, so the pair understates how much media
      # exists by up to one fragment. `note_live_fragment/2` is the pair without
      # that surplus; this one is what an event has until a fragment arrives.
      drain_wall_ms = DateTime.to_unix(DateTime.utc_now(), :millisecond)

      state = %{state | io: io, path: path, anchor: anchor(drained, event, drain_wall_ms)}

      state =
        if is_binary(init) do
          write!(state, init)
        else
          Logger.warning("event #{event.id}: no init segment in ring, clip may be unplayable")
          state
        end

      state = Enum.reduce(drained, state, &write_fragment(&2, &1))

      :telemetry.execute(
        [:cairn, :extractor, :drained],
        %{fragments: length(drained), bytes: state.bytes},
        %{camera_id: camera.id, event_id: event.id}
      )

      {:noreply, state}
    else
      {:error, reason} ->
        Logger.error("event #{event.id}: extractor could not start: #{inspect(reason)}")
        {:stop, {:shutdown, {:open_failed, reason}}, state}
    end
  end

  @impl true
  def handle_info({:ring_fragment, frag}, state) do
    # The anchor before the write: `write_fragment/2` can block on a datasync,
    # and the wall clock this fragment is paired with has to be the one at its
    # arrival.
    {:noreply, state |> note_live_fragment(frag) |> write_fragment(frag)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_cast({:track_boxes, %{t_ms: t_ms, boxes: boxes}}, state) do
    {:noreply, buffer_boxes(state, t_ms, boxes)}
  end

  def handle_cast({:finalize, event}, state) do
    snapshot_fun = Keyword.get(state.opts, :snapshot_fun, &Cairn.Snapshot.take_async/2)
    {outcome, bytes} = close_clip(event, state)

    case outcome do
      {:ok, row} ->
        # Ahead of the broadcast: a consumer that answers `:event_clip_ready`
        # by fetching the sidecar must not race the write that produces it.
        write_track_path(event, state)

        # After the row, which is what makes `clip_url` resolve, and before
        # the snapshot is kicked off, so a consumer always sees the clip's
        # outcome ahead of the snapshot's.
        EventArtifact.broadcast(:event_clip_ready, %EventArtifact{
          event_id: event.id,
          camera_id: state.camera.id,
          path: state.path,
          bytes: bytes
        })

        snapshot_fun.(row, state.config)

      {:error, reason} ->
        Logger.error("event #{event.id}: finalize failed: #{inspect(reason)}")

        EventArtifact.broadcast(:event_clip_failed, %EventArtifact{
          event_id: event.id,
          camera_id: state.camera.id,
          reason: clip_reason(reason)
        })
    end

    :telemetry.execute(
      [:cairn, :extractor, :finalized],
      %{
        bytes: bytes,
        fragments: state.fragments,
        write_duration_ms: System.monotonic_time(:millisecond) - state.started_ms
      },
      %{camera_id: state.camera.id, event_id: event.id}
    )

    {:stop, :normal, %{state | io: nil}}
  end

  # -- internals --------------------------------------------------------------

  # The drain half of the anchor: a media position and the wall clock read
  # beside it, captured while the head of the clip is still in hand. The live
  # half is `nil` here and stays that way until a fragment arrives.
  #
  # An empty pre-window — a camera whose ring has not filled yet — has no media
  # position to offer, so `drained_span_ms` goes `nil` along with the two pts
  # fields and this half can place nothing at all. That file is placeable only
  # once the live half lands (`Cairn.TrackPath` reads every field with
  # `Map.get/2` and skips a half it cannot use).
  defp anchor([], event, drain_wall_ms) do
    %{
      first_pts: nil,
      timescale: nil,
      drained_span_ms: nil,
      drain_wall_ms: drain_wall_ms,
      live_media_ms: nil,
      live_wall_ms: nil,
      event_started_ms: DateTime.to_unix(event.started_at, :millisecond)
    }
  end

  defp anchor([first | _] = drained, event, drain_wall_ms) do
    last = List.last(drained)

    %{
      first_pts: first.pts,
      timescale: first.timescale,
      # `pts` is a decode time, so the difference between the first and the
      # last spans the pre-roll's *starts*; the last fragment's own duration is
      # what carries it to the end of the drained media.
      drained_span_ms: round((last.pts - first.pts) * 1000 / first.timescale) + last.duration_ms,
      drain_wall_ms: drain_wall_ms,
      live_media_ms: nil,
      live_wall_ms: nil,
      event_started_ms: DateTime.to_unix(event.started_at, :millisecond)
    }
  end

  # The live half: the wall clock at the arrival of the first fragment to reach
  # us live, paired with the media position that fragment *ends* at. A fragment
  # is handed over only once it is complete, so this pair is off by the
  # transport and the demux and nothing else — where the drain's pair also
  # carries however much of the in-flight fragment ffmpeg had not written yet.
  #
  # One-shot, and `live_wall_ms` being nil is the whole of the test: the second
  # clause takes every later fragment, and a nil anchor with it.
  defp note_live_fragment(%{anchor: %{live_wall_ms: nil} = anchor} = state, frag) do
    anchor = %{
      anchor
      | live_wall_ms: DateTime.to_unix(DateTime.utc_now(), :millisecond),
        live_media_ms: live_media_ms(anchor, frag)
    }

    %{state | anchor: anchor}
  end

  defp note_live_fragment(state, _frag), do: state

  # Where a live fragment ends on the clip's own timeline, in ms from the t=0
  # `Cairn.ClipRemux` rebases the clip to — the first fragment the file holds.
  # The two clauses are `anchor/3`'s two, in the same order and for the same
  # reason.
  #
  # A `first_pts` of nil is an empty drain, so the fragment in hand is itself
  # the first thing written after the init segment: it starts at the clip's t=0
  # and its own duration is where it ends. Otherwise the clip starts at the head
  # of the drain and the position is measured from that `pts`. Either way the
  # fragment's duration is what carries a decode time to the end of its media.
  #
  # An ffmpeg respawn mid-event restarts `pts` near zero while `first_pts` still
  # names the old session, which makes the difference negative. Nothing is done
  # about it here: a negative media position is what `Cairn.TrackPath` rejects a
  # half on, and the drain half answers instead.
  defp live_media_ms(%{first_pts: nil}, frag), do: frag.duration_ms

  defp live_media_ms(%{first_pts: first_pts, timescale: timescale}, frag) do
    round((frag.pts - first_pts) * 1000 / timescale) + frag.duration_ms
  end

  # Prepend and count. Never `++`, and never `length/1` over the accumulator:
  # this runs once per observation batch for the whole life of the event, and
  # the accumulator is the thing that grows.
  #
  # The cap is a clean tail cut. The first batch that would cross it is dropped
  # whole rather than split, and every batch after it is dropped too, however
  # small — that is what the first clause is for. Letting later batches that
  # still fit trickle in would leave the stored path sampled at random
  # intervals with nothing marking the holes, and a viewer draws a straight
  # line across each one; a path that simply stops is the honest answer, and
  # `truncated` in the header is what explains it. An event long enough to
  # reach the cap has already recorded the minutes someone opened it for, and
  # the tail is the cheaper end to lose.
  defp buffer_boxes(%{track_truncated: true} = state, _t_ms, _boxes), do: state
  defp buffer_boxes(state, _t_ms, []), do: state

  defp buffer_boxes(state, t_ms, boxes) do
    count = length(boxes)

    if state.track_entries + count > state.max_path_entries do
      warn_capped(state)
    else
      %{
        state
        | track_boxes: [{t_ms, boxes} | state.track_boxes],
          track_entries: state.track_entries + count
      }
    end
  end

  # Reached exactly once per event: the batch that trips the cap sets the flag,
  # and the clause above drops every later batch without coming back here. At
  # the ~10 batches a second the aggregator forwards, a per-batch line would be
  # a log file.
  defp warn_capped(state) do
    Logger.warning(
      "event #{state.event.id}: track path capped at #{state.max_path_entries} boxes; " <>
        "the rest of the event is not recorded in it"
    )

    %{state | track_truncated: true}
  end

  # The sidecar, and only for a clip the index accepted: the failure branches
  # never call this, and an event whose recording crashed never reaches
  # finalize at all. An event that buffered no boxes writes no file either —
  # "has this event a path to draw" is then one `File.exists?` for every case
  # rather than a decode that finds zero tracks.
  #
  # Non-fatal, and total: the clip and its row are already good by the time
  # this runs, so nothing here may change what the event is announced as. A
  # failure leaves the same absent file as an event with no boxes.
  defp write_track_path(_event, %{track_boxes: []}), do: :ok

  defp write_track_path(event, state) do
    header = %{
      event_id: event.id,
      camera_id: state.camera.id,
      truncated: state.track_truncated,
      anchor: state.anchor
    }

    case File.write(
           DataDir.trackpath_for_clip(state.path),
           TrackPath.encode(header, state.track_boxes)
         ) do
      :ok -> :ok
      {:error, reason} -> log_track_path_failed(event, inspect(reason))
    end
  rescue
    # As broad as `close_clip/2`'s rescue and for the same reason: this call
    # sits after `:event_ended` and before `:event_clip_ready`, so anything
    # raised in encoding or writing would strand a consumer waiting on a frame
    # for a clip that is finished and indexed. The sidecar is the one thing
    # here that is allowed to be lost.
    e -> log_track_path_failed(event, Exception.message(e))
  end

  defp log_track_path_failed(event, reason) do
    Logger.error("event #{event.id}: track path write failed: #{reason}")
  end

  # Everything between "the window closed" and "we know what the clip is":
  # closing a `:delayed_write` handle (a deferred write error surfaces here),
  # the remux (ffmpeg port, File ops) and the index update (Ecto can raise, or
  # *exit* on a pool checkout timeout). All of it is bracketed because
  # `:event_ended` has already gone out by the time this runs: dying here would
  # leave a consumer that committed to waiting for `clip_ready`/`clip_failed`
  # waiting forever. The broadcast itself is deliberately outside, so a failure
  # after it can never contradict a frame already on the wire.
  defp close_clip(event, state) do
    RingBuffer.unsubscribe(state.camera.id, self())
    File.close(state.io)
    bytes = maybe_remux(state)
    {Events.finalize(event, bytes), bytes}
  rescue
    e ->
      Logger.error("event #{event.id}: finalize crashed: #{Exception.message(e)}")
      {{:error, :exception}, state.bytes}
  catch
    :exit, reason ->
      Logger.error("event #{event.id}: finalize exited: #{inspect(reason)}")
      {{:error, :exception}, state.bytes}
  end

  # `Events.finalize` can fail because the row vanished under us (retention
  # deleted the event mid-recording) or because the update was rejected; keep
  # the wire reason to that closed set.
  defp clip_reason(:not_found), do: :not_found
  defp clip_reason(:exception), do: :exception
  defp clip_reason(_other), do: :index_write_failed

  # Runs before the row is finalized so `bytes` and the snapshot both see the
  # rewritten file. Costs one extra read+write of the clip; `remux_clips:
  # false` skips it for setups that care more about disk writes than about
  # clips reporting their true length (see `Cairn.ClipRemux`).
  defp maybe_remux(%{config: %{remux_clips: false}} = state), do: state.bytes

  defp maybe_remux(state) do
    remux_fun = Keyword.get(state.opts, :remux_fun, &Cairn.ClipRemux.run/1)

    case remux_fun.(state.path) do
      {:ok, size} -> size
      :error -> state.bytes
    end
  end

  defp write_fragment(state, frag) do
    state = write!(state, frag.data)
    state = %{state | fragments: state.fragments + 1}
    maybe_sync(%{state | unsynced_media_ms: state.unsynced_media_ms + frag.duration_ms})
  end

  defp write!(state, data) do
    :ok = :file.write(state.io, data)
    %{state | bytes: state.bytes + byte_size(data)}
  end

  defp maybe_sync(%{unsynced_media_ms: ms} = state) when ms >= @fsync_media_ms do
    :file.datasync(state.io)
    %{state | unsynced_media_ms: 0}
  end

  defp maybe_sync(state), do: state
end
