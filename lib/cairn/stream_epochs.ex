defmodule Cairn.StreamEpochs do
  @moduledoc """
  ETS-backed per-camera *stream epoch*: a ULID naming one continuous decode
  of a camera's stream, minted on every ffmpeg (re)spawn.

  Detections, fragments and init segments produced under one epoch are not
  comparable with those of the next: after an outage the camera may have
  moved, so object ids and pts continuity must not survive the boundary.
  Consumers subscribe to `"stream_epochs"` for `{:stream_epoch, camera_id,
  epoch, reason}` and/or read `current/1` straight from ETS.

  Written by `Cairn.FFmpegPort`; read by `Cairn.DetectionAggregator` and
  the ring buffer's init-segment metadata.

  The table is owned by this GenServer and dies with it: after a crash every
  camera reads back `:unknown` until its next spawn re-mints. That is
  accepted — the aggregator ends tracks on epoch *change*, and a re-mint is
  a change, which is exactly the conservative outcome.
  """

  use GenServer

  @table __MODULE__
  @topic "stream_epochs"

  @type reason :: :started | :source_lost | :stall_bounce | :camera_stopped

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Broadcasts `{:stream_epoch, camera_id, epoch, reason}` on every mint."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Cairn.PubSub, @topic)

  @doc """
  Mints, stores and broadcasts a new epoch for `camera_id`, returning it.

  `:camera_stopped` mints an epoch nobody streams under — it is how the end
  of a stream is announced to subscribers.
  """
  @spec new_epoch(String.t(), reason()) :: Cairn.ULID.t()
  def new_epoch(camera_id, reason) do
    GenServer.call(__MODULE__, {:new_epoch, camera_id, reason})
  end

  @doc "Current epoch for `camera_id`, read directly from ETS."
  @spec current(String.t()) :: {:ok, Cairn.ULID.t()} | :unknown
  def current(camera_id) do
    # the table is gone between an owner crash and its restart
    case :ets.whereis(@table) do
      :undefined ->
        :unknown

      table ->
        case :ets.lookup(table, camera_id) do
          [{^camera_id, epoch, _started_at}] -> {:ok, epoch}
          [] -> :unknown
        end
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:new_epoch, camera_id, reason}, _from, state) do
    epoch = Cairn.ULID.generate()
    :ets.insert(@table, {camera_id, epoch, DateTime.utc_now()})
    Phoenix.PubSub.broadcast(Cairn.PubSub, @topic, {:stream_epoch, camera_id, epoch, reason})
    {:reply, epoch, state}
  end
end
