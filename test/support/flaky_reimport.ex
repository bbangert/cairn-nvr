defmodule Cairn.FlakyReimport do
  @moduledoc """
  A `Config.Server` stand-in that fails only the `{:update, ...}` call the
  re-import button drives, so the async task exits the way an unconfirmed
  write would — without also breaking `ConfigLive.load/1`'s `get`/`last_load`
  reads the way a genuinely dead or hung server would (that's the busy
  overlay, a different code path than the one under test).

  Registered under a fixed name, not a bare pid: `handle_call`'s `exit/1`
  crashes this process (that's what makes `GenServer.call`'s own machinery
  raise *inside* the calling async task, where `do_async`'s `try/catch` can
  see it — a `Process.exit/2` sent to the caller instead would bypass that
  catch and corrupt the task's link to the LiveView), and `start_supervised!`
  restarts it under the same name afterward. Forwarding calls in the
  restarted, crashed-once instance keep working precisely because
  `Cameras.server()` resolves the name, not the pid that has since changed.
  """
  use GenServer

  def start_link(real), do: GenServer.start_link(__MODULE__, real, name: __MODULE__)

  @impl true
  def init(real), do: {:ok, real}

  @impl true
  def handle_call({:update, _write_fun, _reject, _after_apply}, _from, _real),
    do: exit(:simulated_write_failure)

  def handle_call(msg, _from, real), do: {:reply, GenServer.call(real, msg), real}
end
