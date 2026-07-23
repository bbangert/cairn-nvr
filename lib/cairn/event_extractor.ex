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
  bytes, labels, max_score), kicks off the async snapshot, emits
  `[:cairn, :extractor, :finalized]` telemetry, exits `:normal`. A crash
  leaves the row `active`; boot reconciliation marks it `partial`.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Cairn.{DataDir, Events, RingBuffer}

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
      config: Keyword.get_lazy(opts, :config, &Cairn.Config.Server.get/0),
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
    RingBuffer.unsubscribe(state.camera.id, self())
    File.close(state.io)

    snapshot_fun = Keyword.get(state.opts, :snapshot_fun, &Cairn.Snapshot.take_async/2)

    case Events.finalize(event, state.bytes) do
      {:ok, row} -> snapshot_fun.(row, state.config)
      {:error, reason} -> Logger.error("event #{event.id}: finalize failed: #{inspect(reason)}")
    end

    :telemetry.execute(
      [:cairn, :extractor, :finalized],
      %{
        bytes: state.bytes,
        fragments: state.fragments,
        write_duration_ms: System.monotonic_time(:millisecond) - state.started_ms
      },
      %{camera_id: state.camera.id, event_id: event.id}
    )

    {:stop, :normal, %{state | io: nil}}
  end

  # -- internals --------------------------------------------------------------

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
