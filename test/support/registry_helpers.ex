defmodule Cairn.RegistryHelpers do
  @moduledoc """
  Deterministic control over `Cairn.Registry`'s reaping window.

  A registry entry outlives its process. `Registry.register/3`,
  `Registry.unregister/2` and `Registry.lookup/2` are all caller-side ETS, but
  an entry whose owner *died* is removed only when the registry partition
  handles the `:DOWN` it holds on that pid — a separate process, a moment
  later. Code that reads the registry inside that window sees a corpse as
  running; see
  `.claude/solutions/terminate-child-then-sync-registry-race-20260726.md`.

  Suspending the partition holds the window open for as long as a test needs,
  and blocks nothing else: only the reaping goes through that process.

  For `async: false` modules only — the partition is shared by the whole
  application. ExUnit runs every async module to completion before any sync
  one, so nothing else is touching the registry while it is down.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc """
  Stops the registry from reaping entries for dead processes until the test ends.

  Returns the partition pid.
  """
  @spec suspend_registry_reaping() :: pid()
  def suspend_registry_reaping do
    partition = registry_partition()

    # `on_exit` runs in the ExUnit on_exit process, so the resume survives the
    # test process being *killed* (an ExUnit timeout, or an exit signal from
    # anything linked into it) — `try/after` does not, and a partition left
    # suspended wedges every later test that waits for a dead process to
    # disappear from the registry. Registered before the suspend so no window
    # exists in which a leak is possible; resuming a running process is a
    # no-op, so an extra resume is harmless.
    on_exit(fn -> :sys.resume(partition) end)
    :sys.suspend(partition)

    partition
  end

  @doc """
  Leaves `{camera_id, role}` registered to a process that is already dead.

  Registers from a throwaway process, suspends reaping, then lets that process
  exit `:normal`. The returned pid is dead, but `Cairn.Registry.whereis/2`
  still hands it back for the rest of the test — the exact production window a
  reader has to survive.
  """
  @spec stale_entry(String.t(), Cairn.Registry.role()) :: pid()
  def stale_entry(camera_id, role) do
    test = self()

    owner =
      spawn(fn ->
        {:ok, _} = Registry.register(Cairn.Registry, {camera_id, role}, nil)
        send(test, {:registered, self()})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:registered, ^owner}, 1_000

    # suspend before the owner dies, or the partition may reap it first
    suspend_registry_reaping()

    ref = Process.monitor(owner)
    send(owner, :stop)
    assert_receive {:DOWN, ^ref, :process, ^owner, :normal}, 1_000

    assert Cairn.Registry.whereis(camera_id, role) == owner,
           "the registry reaped #{inspect({camera_id, role})} despite the suspend"

    owner
  end

  # `Cairn.Registry` is a `Registry.Supervisor` with the default single
  # partition, and that one child is the process that reaps entries for dead
  # owners. The one-element match fails loudly if it ever gains partitions,
  # rather than suspending an arbitrary one of them.
  defp registry_partition do
    [{_id, pid, _type, _modules}] = Supervisor.which_children(Cairn.Registry)
    pid
  end
end
