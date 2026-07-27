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

  The *caller* mints the ULID and hands it to the server, which stores and
  broadcasts exactly that value: the epoch returned here, the one in ETS and
  the one carried by the broadcast are always the same. That matters because
  a `GenServer.call/3` that exits with `:timeout` leaves the request queued —
  a server that minted its own would later store and announce an epoch the
  caller never saw, while the caller's already tags ring-buffer init segments.

  The cost of the contract is that one mint may be *announced twice* (the
  degraded path below broadcasts, and a call that timed out may still be
  served). Consumers must treat a repeat of the epoch they already hold as a
  no-op — see `Cairn.DetectionAggregator`.

  `:camera_stopped` mints an epoch nobody streams under — it is how the end
  of a stream is announced to subscribers.

  `timeout` bounds the wait on this server. Callers running under a shutdown
  budget (a supervisor's worker timeout) must pass one well below it, or a
  wedged server eats the budget and they are brutally killed mid-cleanup.
  """
  @spec new_epoch(String.t(), reason(), timeout()) :: Cairn.ULID.t()
  def new_epoch(camera_id, reason, timeout \\ 5000) do
    epoch = Cairn.ULID.generate()

    try do
      GenServer.call(__MODULE__, {:new_epoch, camera_id, epoch, reason}, timeout)
      epoch
    catch
      :exit, _ ->
        # This server being down (restart window, overload) or too slow must
        # never take a camera with it: announce locally so the caller still
        # gets a usable epoch. The ETS row may stay missing until the next
        # successful mint, so `current/1` can answer `:unknown` in the meantime
        # — the same state a restart leaves behind anyway, and a re-mint is a
        # change, which is the conservative outcome for consumers.
        try_broadcast(camera_id, epoch, reason)
        epoch
    end
  end

  @doc "Current epoch for `camera_id`, read directly from ETS."
  @spec current(String.t()) :: {:ok, Cairn.ULID.t()} | :unknown
  def current(camera_id) do
    case :ets.lookup(@table, camera_id) do
      [{^camera_id, epoch, _started_at}] -> {:ok, epoch}
      [] -> :unknown
    end
  rescue
    # the table is gone between an owner crash and its restart. Checking
    # `:ets.whereis/1` first would not help: it is not atomic with the lookup.
    ArgumentError -> :unknown
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:new_epoch, camera_id, epoch, reason}, _from, state) do
    # the epoch is the caller's; this server never mints one of its own. See
    # new_epoch/3 for why.
    #
    # Open question, deliberately unanswered: two calls minted close together
    # can be served out of order, rolling `current/1` back to an older but
    # legitimate epoch (plain ULIDs only order across milliseconds). A
    # per-camera monotonic guard — ignore an insert whose epoch sorts below
    # the stored one — would go here, ahead of the insert.
    #
    # insert before the broadcast: a subscriber reacting to {:stream_epoch, e}
    # by calling current/1 must never read something staler than e
    :ets.insert(@table, {camera_id, epoch, DateTime.utc_now()})
    broadcast(camera_id, epoch, reason)
    {:reply, :ok, state}
  end

  # local_broadcast, not broadcast: the epoch table is a node-local named ETS
  # table, so a remote subscriber could never resolve what it was told about.
  defp broadcast(camera_id, epoch, reason) do
    Phoenix.PubSub.local_broadcast(
      Cairn.PubSub,
      @topic,
      {:stream_epoch, camera_id, epoch, reason}
    )
  end

  # Degraded path only: it runs in the caller (a camera's spawn or shutdown
  # path), where
  # a best-effort announcement must not raise. PubSub being down raises
  # ArgumentError from its registry lookup.
  defp try_broadcast(camera_id, epoch, reason) do
    broadcast(camera_id, epoch, reason)
  rescue
    ArgumentError -> :ok
  catch
    :exit, _ -> :ok
  end
end
