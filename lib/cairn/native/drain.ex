defmodule Cairn.Native.Drain do
  @moduledoc """
  Holds the node's shutdown open until the native teardown threads finish.

  Both NIF libraries defer slow destructor work — an ORT/QNN session release,
  a hardware decoder close — onto a detached `cairn-teardown` thread, and a VM
  that halts while that thread is mid-drop races process teardown against a
  native destructor. On QCS6490 that race was observed at exit, after all work
  completed, as both a heap-corruption abort and a hang inside fastrpc deinit
  (membrane-port `research/board-first-light.md`).

  Started *first* in the application tree precisely so it terminates *last*:
  supervisors stop children in reverse start order, so every camera and the
  host have already died — and queued their drops — by the time this
  `terminate/2` runs the bounded drains. The concrete modules are called
  directly rather than through the host's injectable seams: the drain is about
  the real libraries loaded in this VM, whatever a test stubbed above them.
  """

  use GenServer

  require Logger

  @drain_timeout_ms 5_000
  # The supervisor's patience must exceed terminate/2's worst case — two
  # sequential drains — or it kills this process mid-drain and silently skips
  # the second library, reopening the exact race the module closes. Derived,
  # not restated, so the numbers cannot drift apart.
  @shutdown_ms 2 * @drain_timeout_ms + 1_000

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      shutdown: @shutdown_ms
    }
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    # Without trapping, a supervisor shutdown kills this process before
    # `terminate/2` runs — the flag is the whole mechanism.
    Process.flag(:trap_exit, true)
    {:ok, %{notify: Keyword.get(opts, :notify)}}
  end

  @impl true
  def terminate(_reason, state) do
    drain(CairnOrt, state)
    drain(Cairn.Native, state)
  end

  # `:logger` lives outside this application's tree, so the warning below is
  # still deliverable this late in the shutdown.
  defp drain(module, state) do
    drained = not module.available?() or module.drain_teardown(@drain_timeout_ms)

    # A test-only observable: terminate/2 has no return anyone reads, and this
    # module deliberately calls the concrete NIF modules, so without the
    # notification a no-op terminate would be indistinguishable from a working
    # one (the review's W5).
    if pid = state[:notify], do: send(pid, {:drained, module, drained})

    unless drained do
      # The halt proceeds regardless — this is the one warning that says a
      # crash or hang in the next moments is the teardown race, not a new bug.
      Logger.warning(
        "#{inspect(module)}: native teardown still running after " <>
          "#{@drain_timeout_ms} ms; halting into it"
      )
    end
  end
end
