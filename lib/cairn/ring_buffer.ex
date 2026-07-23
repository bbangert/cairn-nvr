defmodule Cairn.RingBuffer do
  @moduledoc """
  Per-camera in-memory ring of recent fmp4 fragments, sized by the
  pre-event window (pts-based, timescale-aware).

  Fan-out on every fragment:

    * PubSub broadcast `{:fragment, frag}` on `"camera:{id}:fragments"` and
      `{:init_segment, meta}` on session start — for MSE/HLS viewers where
      a race at the boundary doesn't matter.
    * Direct `send(pid, {:ring_fragment, frag})` to subscribers registered
      through `drain_and_subscribe/3` — the race-free path for event
      extractors (drain + subscribe happen atomically in one call).

  A new init segment (ffmpeg respawn) clears the ring: pts restart at ~0,
  so pre-window content from the old session is no longer addressable.
  Fragment `seq` is re-stamped with a per-camera counter that is monotonic
  across sessions (HLS media sequence relies on this).
  """

  use GenServer

  alias Cairn.Fragment

  defstruct camera_id: nil,
            pre_window_seconds: 5,
            frags: :queue.new(),
            count: 0,
            init: nil,
            codec: nil,
            timescale: 90_000,
            next_seq: 0,
            subscribers: %{},
            last_fragment_at: nil

  # -- client -----------------------------------------------------------------

  def start_link(opts) do
    camera_id = Keyword.fetch!(opts, :camera_id)
    GenServer.start_link(__MODULE__, opts, name: Cairn.Registry.via(camera_id, :ring_buffer))
  end

  @doc "PubSub topic carrying `{:fragment, t}` / `{:init_segment, meta}`."
  @spec topic(String.t()) :: String.t()
  def topic(camera_id), do: "camera:#{camera_id}:fragments"

  @spec put_init(String.t(), binary(), String.t() | nil, pos_integer()) :: :ok
  def put_init(camera_id, data, codec, timescale) do
    GenServer.cast(name(camera_id), {:init, data, codec, timescale})
  end

  @spec put_fragment(String.t(), Fragment.t()) :: :ok
  def put_fragment(camera_id, %Fragment{} = frag) do
    GenServer.cast(name(camera_id), {:fragment, frag})
  end

  @doc """
  Atomically returns the init segment plus all buffered fragments with
  `pts >= since_pts` and registers `pid` (monitored) to receive every
  subsequent fragment as `{:ring_fragment, frag}`.
  """
  @spec drain_and_subscribe(String.t(), non_neg_integer() | nil, pid()) ::
          {:ok, %{init: binary() | nil, codec: String.t() | nil, fragments: [Fragment.t()]}}
  def drain_and_subscribe(camera_id, since_pts, pid) do
    GenServer.call(name(camera_id), {:drain_and_subscribe, since_pts, pid})
  end

  @spec unsubscribe(String.t(), pid()) :: :ok
  def unsubscribe(camera_id, pid) do
    GenServer.cast(name(camera_id), {:unsubscribe, pid})
  end

  @doc "Monotonic ms timestamp of the last fragment, or nil (for the watchdog)."
  @spec last_fragment_at(String.t()) :: integer() | nil
  def last_fragment_at(camera_id) do
    GenServer.call(name(camera_id), :last_fragment_at)
  end

  @doc "Init segment, codec and the most recent `count` fragments (for HLS)."
  @spec fetch_recent(String.t(), pos_integer()) ::
          {:ok, %{init: binary() | nil, codec: String.t() | nil, fragments: [Fragment.t()]}}
  def fetch_recent(camera_id, count) do
    GenServer.call(name(camera_id), {:fetch_recent, count})
  end

  defp name(camera_id), do: Cairn.Registry.via(camera_id, :ring_buffer)

  # -- server -----------------------------------------------------------------

  @impl true
  def init(opts) do
    {:ok,
     %__MODULE__{
       camera_id: Keyword.fetch!(opts, :camera_id),
       pre_window_seconds: Keyword.get(opts, :pre_window_seconds, 5)
     }}
  end

  @impl true
  def handle_cast({:init, data, codec, timescale}, state) do
    meta = %{camera_id: state.camera_id, codec: codec, timescale: timescale}
    broadcast(state, {:init_segment, meta})

    {:noreply,
     %{state | init: data, codec: codec, timescale: timescale, frags: :queue.new(), count: 0}}
  end

  def handle_cast({:fragment, %Fragment{} = frag}, state) do
    frag = %{frag | seq: state.next_seq}

    state = %{
      state
      | frags: :queue.in(frag, state.frags),
        count: state.count + 1,
        next_seq: state.next_seq + 1,
        last_fragment_at: System.monotonic_time(:millisecond)
    }

    state = evict(state)

    broadcast(state, {:fragment, frag})
    Enum.each(state.subscribers, fn {pid, _ref} -> send(pid, {:ring_fragment, frag}) end)

    {:noreply, state}
  end

  def handle_cast({:unsubscribe, pid}, state) do
    {:noreply, remove_subscriber(state, pid)}
  end

  @impl true
  def handle_call({:drain_and_subscribe, since_pts, pid}, _from, state) do
    fragments =
      for frag <- :queue.to_list(state.frags),
          is_nil(since_pts) or frag.pts >= since_pts,
          do: frag

    state =
      if Map.has_key?(state.subscribers, pid) do
        state
      else
        ref = Process.monitor(pid)
        %{state | subscribers: Map.put(state.subscribers, pid, ref)}
      end

    {:reply, {:ok, %{init: state.init, codec: state.codec, fragments: fragments}}, state}
  end

  def handle_call(:last_fragment_at, _from, state) do
    {:reply, state.last_fragment_at, state}
  end

  def handle_call({:fetch_recent, count}, _from, state) do
    fragments = state.frags |> :queue.to_list() |> Enum.take(-count)
    {:reply, {:ok, %{init: state.init, codec: state.codec, fragments: fragments}}, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, remove_subscriber(state, pid)}
  end

  # -- internals --------------------------------------------------------------

  defp evict(%{count: count} = state) when count < 2, do: state

  defp evict(state) do
    {:value, first} = :queue.peek(state.frags)
    last = :queue.get_r(state.frags)
    span = last.pts + last.duration_ms * div(last.timescale, 1000) - first.pts

    if span > state.pre_window_seconds * first.timescale do
      {_, frags} = :queue.out(state.frags)
      evict(%{state | frags: frags, count: state.count - 1})
    else
      state
    end
  end

  defp remove_subscriber(state, pid) do
    case Map.pop(state.subscribers, pid) do
      {nil, _} ->
        state

      {ref, subscribers} ->
        Process.demonitor(ref, [:flush])
        %{state | subscribers: subscribers}
    end
  end

  defp broadcast(state, message) do
    Phoenix.PubSub.broadcast(Cairn.PubSub, topic(state.camera_id), message)
  end
end
