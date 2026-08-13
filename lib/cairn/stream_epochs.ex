defmodule Cairn.StreamEpochs do
  @moduledoc """
  ETS-backed per-stream *stream epoch*: a ULID naming one continuous decode of
  one of a camera's streams, minted from the stream itself as each session's
  first buffer is produced.

  The table is keyed `{camera_id, role}` with role `:main | :sub`. A camera with
  a `substream_url` runs two ingests whose sessions die and reconnect
  independently, so they carry independent epochs: the recording side follows
  `:main`, the detect branch follows whichever role feeds it. Every function
  here takes either a bare `camera_id` — which means `:main`, and is what a
  single-stream camera's callers keep passing — or an explicit
  `{camera_id, role}`.

  Detections, fragments and init segments produced under one epoch are not
  comparable with those of the next: after an outage the camera may have
  moved, so object ids and pts continuity must not survive the boundary.
  Consumers subscribe to `"stream_epochs"` for `{:stream_epoch, camera_id,
  role, epoch, reason}` and/or read `current/1` straight from ETS. A subscriber
  sees every role of every camera and must filter: an epoch is only about the
  stream it names.

  Written by `Cairn.Pipeline.EpochTagger` (every session, under the role of the
  pad it sits behind) and `Cairn.PipelineOwner` (`:camera_stopped`, on a
  deliberate stop only, once per role the camera runs); read by
  `Cairn.CameraTracker`'s staleness gate, the ring buffer's init-segment
  metadata, and the owner itself, which no longer knows an epoch first-hand.

  The table is owned by this GenServer and dies with it: after a crash every
  stream reads back `:unknown` until its next session re-mints. That is
  accepted — the tracker element cuts its live set on epoch *change*, and a
  re-mint is a change, which is exactly the conservative outcome.
  """

  use GenServer

  @table __MODULE__
  @topic "stream_epochs"

  @type reason :: :started | :source_lost | :stall_bounce | :camera_stopped
  @type role :: :main | :sub

  @typedoc "A camera's stream: `{camera_id, role}`, or a bare id meaning `:main`."
  @type stream :: String.t() | {String.t(), role()}

  @roles [:main, :sub]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Broadcasts `{:stream_epoch, camera_id, role, epoch, reason}` on every mint."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Cairn.PubSub, @topic)

  @doc """
  Mints, stores and broadcasts a new epoch for `stream`, returning it.

  The *caller* mints the ULID and hands it to the server, which stores and
  broadcasts exactly that value: the epoch returned here, the one in ETS and
  the one carried by the broadcast are always the same. That matters because
  a `GenServer.call/3` that exits with `:timeout` leaves the request queued —
  a server that minted its own would later store and announce an epoch the
  caller never saw, while the caller's already tags ring-buffer init segments.

  The cost of the contract is that one mint may be *announced twice* (the
  degraded path below broadcasts, and a call that timed out may still be
  served). Consumers must treat a repeat of the epoch they already hold as a
  no-op — see `Cairn.CameraTracker`.

  Every guarantee here is per stream: one role's mint neither supersedes nor
  announces anything about the other's.

  `:camera_stopped` mints an epoch nobody streams under — it is how the end
  of a stream is announced to subscribers. A stop takes every one of the
  camera's streams, so its owner mints it once per role.

  `timeout` bounds the wait on this server. Callers running under a shutdown
  budget (a supervisor's worker timeout) must pass one well below it, or a
  wedged server eats the budget and they are brutally killed mid-cleanup — and
  a caller minting for several roles pays it once per role.
  """
  @spec new_epoch(stream(), reason(), timeout()) :: Cairn.ULID.t()
  def new_epoch(stream, reason, timeout \\ 5000) do
    key = key(stream)
    epoch = Cairn.ULID.generate()

    try do
      GenServer.call(__MODULE__, {:new_epoch, key, epoch, reason}, timeout)
      epoch
    catch
      :exit, _ ->
        # This server being down (restart window, overload) or too slow must
        # never take a camera with it: announce locally so the caller still
        # gets a usable epoch. The ETS row may stay missing until the next
        # successful mint, so `current/1` can answer `:unknown` in the meantime
        # — the same state a restart leaves behind anyway, and a re-mint is a
        # change, which is the conservative outcome for consumers.
        try_broadcast(key, epoch, reason)
        epoch
    end
  end

  @doc "Current epoch for `stream`, read directly from ETS."
  @spec current(stream()) :: {:ok, Cairn.ULID.t()} | :unknown
  def current(stream) do
    key = key(stream)

    case :ets.lookup(@table, key) do
      [{^key, epoch, _started_at}] -> {:ok, epoch}
      [] -> :unknown
    end
  rescue
    # the table is gone between an owner crash and its restart. Checking
    # `:ets.whereis/1` first would not help: it is not atomic with the lookup.
    ArgumentError -> :unknown
  end

  @doc """
  The role of the camera's stream currently running under `epoch`, if any.

  For a holder of an epoch that has no idea which stream produced it —
  `Cairn.Native.Host` adopts whatever epoch its caller opened under — this is
  the only honest way back to a role. `:unknown` covers both "no such stream"
  and "that epoch has been superseded".
  """
  @spec role_of(String.t(), Cairn.ULID.t()) :: {:ok, role()} | :unknown
  def role_of(camera_id, epoch) do
    Enum.find_value(@roles, :unknown, fn role ->
      if current({camera_id, role}) == {:ok, epoch}, do: {:ok, role}
    end)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:new_epoch, key, epoch, reason}, _from, state) do
    # the epoch is the caller's; this server never mints one of its own. See
    # new_epoch/3 for why.
    if superseded?(key, epoch) do
      # Two calls minted close together can be served out of order, which
      # would roll `current/1` back to an older but legitimate epoch — and a
      # consumer that had already applied the newer one would then be told to
      # go back to a stream nothing decodes under. Neither stored nor
      # announced: every consumer guards the same way
      # (`Cairn.ULID.superseded?/2`), so an announcement they would discard
      # is not worth sending. The caller still gets its epoch back and tags
      # its own artifacts with it; nothing downstream will match it, which is
      # the same outcome as the mint never having happened.
      {:reply, :ok, state}
    else
      # insert before the broadcast: a subscriber reacting to
      # {:stream_epoch, e} by calling current/1 must never read something
      # staler than e
      :ets.insert(@table, {key, epoch, DateTime.utc_now()})
      broadcast(key, epoch, reason)
      {:reply, :ok, state}
    end
  end

  # Per stream, deliberately: ULIDs are globally time-ordered, so comparing a
  # sub stream's fresh mint against main's would retire it whenever main
  # reconnected last.
  defp superseded?(key, epoch) do
    case current(key) do
      {:ok, held} -> Cairn.ULID.superseded?(held, epoch)
      :unknown -> false
    end
  end

  # local_broadcast, not broadcast: the epoch table is a node-local named ETS
  # table, so a remote subscriber could never resolve what it was told about.
  defp broadcast({camera_id, role}, epoch, reason) do
    Phoenix.PubSub.local_broadcast(
      Cairn.PubSub,
      @topic,
      {:stream_epoch, camera_id, role, epoch, reason}
    )
  end

  # Degraded path only: it runs in the caller (a camera's spawn or shutdown
  # path), where
  # a best-effort announcement must not raise. PubSub being down raises
  # ArgumentError from its registry lookup.
  defp try_broadcast(key, epoch, reason) do
    broadcast(key, epoch, reason)
  rescue
    ArgumentError -> :ok
  catch
    :exit, _ -> :ok
  end

  defp key(camera_id) when is_binary(camera_id), do: {camera_id, :main}
  defp key({camera_id, role} = key) when is_binary(camera_id) and role in @roles, do: key

  # ArgumentError, not a FunctionClauseError: `current/1` already rescues it
  # into `:unknown`, and a caller minting under a role that does not exist
  # deserves the message over a clause dump.
  defp key(other) do
    raise ArgumentError,
          "stream epoch key must be a camera id or {camera_id, role} with " <>
            "role in #{inspect(@roles)}, got: #{inspect(other)}"
  end
end
