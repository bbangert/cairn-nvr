defmodule CairnWeb.Api.StreamLimiter do
  @moduledoc """
  Caps the number of concurrent `/api/stream` (SSE) connections.

  Each SSE connection is a process holding a chunked socket subscribed to
  several PubSub topics; without a cap a token holder could open thousands and
  exhaust file descriptors/memory. Mirrors the `WebRTC.Supervisor`
  `max_children` cap on the WHEP side.

  A slot is a `Registry` entry of the process holding the stream, so it is
  freed when that process dies, however it dies — a counter would leak the
  slot of a handler killed before its `release/0` ran. `Registry.register/3`
  links the holder to the registry: if the registry goes down, its entries go
  with it and each holder gets an exit signal, which ends its stream
  (`CairnWeb.Api.EventStreamController`).
  """

  @key :stream
  @default_max 64

  def child_spec(_opts), do: Registry.child_spec(keys: :duplicate, name: __MODULE__)

  @doc "Configured maximum concurrent SSE connections."
  @spec max() :: pos_integer()
  def max, do: Application.get_env(:cairn, :max_sse_connections, @default_max)

  @doc """
  Claims a slot for the calling process. Returns `:ok`, or `:error` when the
  cap is reached.
  """
  @spec acquire() :: :ok | :error
  def acquire do
    {:ok, _} = Registry.register(__MODULE__, @key, nil)

    # Two callers racing for the last slot may both be refused, never both let in.
    if Registry.count(__MODULE__) <= max() do
      :ok
    else
      release()
      :error
    end
  end

  @doc "Releases the calling process's slot."
  @spec release() :: :ok
  def release do
    Registry.unregister(__MODULE__, @key)
  rescue
    # A registry going down takes the slot with it; until its restart
    # completes, the tables this deletes from may not exist.
    ArgumentError -> :ok
  end

  @doc "Current number of active connections."
  @spec count() :: non_neg_integer()
  def count, do: Registry.count(__MODULE__)
end
