defmodule Cairn.SnapshotHelpers do
  @moduledoc """
  Adds camera ids to the application config server's published snapshot for
  the rest of the test.

  The runtime owners refuse a write for a camera that snapshot does not name,
  so a suite whose camera exists only as a fixture would have its status,
  control and checkpoint writes dropped on the floor. Lending the id is the
  faithful stand-in for a camera the fleet has: the check runs, and passes.

  `async: false` only — the snapshot is one process-global term, and the
  restore is per-test.
  """

  @doc "Names `ids` in the application snapshot until the test ends."
  @spec lend_cameras(String.t() | [String.t()]) :: :ok
  def lend_cameras(ids) do
    key = Cairn.Config.Server.snapshot_key(Cairn.Config.Server)
    restore = :persistent_term.get(key, nil)
    config = restore || Cairn.Config.Server.get()
    lent = Enum.map(List.wrap(ids), &%Cairn.Config.Camera{id: &1})

    :persistent_term.put(key, %{config | cameras: lent ++ config.cameras})

    # Reverse-order on_exit, so nested lends unwind to what each one found.
    ExUnit.Callbacks.on_exit(fn ->
      if restore, do: :persistent_term.put(key, restore), else: :persistent_term.erase(key)
    end)

    :ok
  end
end
