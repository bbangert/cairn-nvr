defmodule Cairn.OwnerStub do
  @moduledoc """
  Stands in for a runtime owner: it subscribes to the config topic like the
  real ones and takes its time over the diff, so a barrier that did not wait
  would return first. Registered under its own name because that is how
  `Cairn.Config.Server` addresses an owner.

  `ignore: n` makes it withhold `:sync`'s reply for the first `n`
  `:config_changed` messages it sees — simulating an owner that missed (or
  has not yet caught up on) the diff the barrier is waiting on — and reply
  only once the `n + 1`th arrives, which is what the barrier's resend on
  retry delivers.
  """

  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def sync(server \\ __MODULE__, timeout \\ 5_000), do: GenServer.call(server, :sync, timeout)

  @impl true
  def init(opts) do
    Cairn.Config.Server.subscribe()

    state =
      opts
      |> Map.new()
      |> Map.put_new(:delay, 0)
      |> Map.put_new(:ignore, 0)
      |> Map.put(:seen, 0)

    {:ok, state}
  end

  # `seen` already counts the diff that unblocked this call (handle_info
  # below runs first — same-process ordering off `local_broadcast/3`), so
  # `>` rather than `>=` is what makes `ignore: n` withhold exactly n replies.
  @impl true
  def handle_call(:sync, _from, %{seen: seen, ignore: ignore} = state) when seen > ignore,
    do: {:reply, :ok, state}

  # Never replies: the caller's `sync` call times out, which is the failure
  # the barrier's retry-and-resend exists to recover from.
  def handle_call(:sync, _from, state), do: {:noreply, state}

  @impl true
  def handle_info({:config_changed, diff}, state) do
    state = Map.update!(state, :seen, &(&1 + 1))

    if state.seen > state.ignore do
      Process.sleep(state.delay)
      send(state.test, {:diff_handled, diff})
    end

    {:noreply, state}
  end
end
