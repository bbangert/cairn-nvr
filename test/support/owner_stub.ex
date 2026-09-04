defmodule Cairn.OwnerStub do
  @moduledoc """
  Stands in for a runtime owner: it subscribes to the config topic like the
  real ones and takes its time over the diff, so a barrier that did not wait
  would return first. Registered under its own name because that is how
  `Cairn.Config.Server` addresses an owner.
  """

  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def sync(server \\ __MODULE__, timeout \\ 5_000), do: GenServer.call(server, :sync, timeout)

  @impl true
  def init(opts) do
    Cairn.Config.Server.subscribe()
    {:ok, Map.new(opts)}
  end

  @impl true
  def handle_call(:sync, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_info({:config_changed, diff}, state) do
    Process.sleep(state.delay)
    send(state.test, {:diff_handled, diff})
    {:noreply, state}
  end
end
