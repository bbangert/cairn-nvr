defmodule Cairn.EventExtractor do
  @moduledoc """
  One `:temporary` process per active event, streaming fragments to a
  single mp4 on disk.

  On start: inserts the `active` index row, opens
  `events/{camera}/{event_id}_{camera}_{ts}.mp4`, writes the init segment,
  then atomically drains the ring's pre-window and subscribes for live
  fragments (`Cairn.RingBuffer.drain_and_subscribe/3` — race-free
  boundary). Memory stays constant w.r.t. event length: fragments are
  written as they arrive, with a datasync roughly every 2s of media.

  Finalize: closes the file, updates the row (`finalized`, ended_at,
  bytes, labels, max_score), broadcasts `:event_clip_ready` with the
  post-remux size (or `:event_clip_failed`), kicks off the async snapshot,
  emits `[:cairn, :extractor, :finalized]` telemetry, exits `:normal`. A
  crash *while recording* leaves the row `active` and announces no artifact at
  all; boot reconciliation marks it `partial`. A crash inside finalize is
  different: `:event_ended` has already been broadcast by then, so the failure
  is caught and announced as `:event_clip_failed` with `:exception` rather
  than leaving a consumer waiting for a frame that is never coming.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Cairn.{Config, DataDir, EventArtifact, Events, RingBuffer}

  @fsync_media_ms 2_000

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
      started_ms: System.monotonic_time(:millisecond)
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

      state = %{state | io: io, path: path}

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
    {:noreply, write_fragment(state, frag)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_cast({:finalize, event}, state) do
    snapshot_fun = Keyword.get(state.opts, :snapshot_fun, &Cairn.Snapshot.take_async/2)
    {outcome, bytes} = close_clip(event, state)

    case outcome do
      {:ok, row} ->
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
