defmodule CairnWeb.Api.StreamLimiter do
  @moduledoc """
  Caps the number of concurrent `/api/stream` (SSE) connections.

  Each SSE connection is a process holding a chunked socket subscribed to
  several PubSub topics; without a cap a token holder could open thousands and
  exhaust file descriptors/memory. Backed by an atomic ETS counter owned by a
  supervised Agent, mirroring the `WebRTC.Supervisor` `max_children` cap on the
  WHEP side.
  """

  use Agent

  @table __MODULE__
  @default_max 64

  def start_link(_opts) do
    Agent.start_link(fn -> init_table() end, name: __MODULE__)
  end

  defp init_table do
    :ets.new(@table, [:named_table, :public, :set])
    :ets.insert(@table, {:count, 0})
    :ok
  end

  @doc "Configured maximum concurrent SSE connections."
  @spec max() :: pos_integer()
  def max, do: Application.get_env(:cairn, :max_sse_connections, @default_max)

  @doc """
  Atomically claims a slot. Returns `:ok`, or `:error` when the cap is reached
  (the speculative increment is rolled back).
  """
  @spec acquire() :: :ok | :error
  def acquire do
    if :ets.update_counter(@table, :count, 1) <= max() do
      :ok
    else
      :ets.update_counter(@table, :count, -1)
      :error
    end
  end

  @doc "Releases a previously-acquired slot."
  @spec release() :: :ok
  def release do
    :ets.update_counter(@table, :count, {2, -1, 0, 0})
    :ok
  end

  @doc "Current number of active connections."
  @spec count() :: non_neg_integer()
  def count do
    case :ets.lookup(@table, :count) do
      [{:count, n}] -> n
      [] -> 0
    end
  end
end
