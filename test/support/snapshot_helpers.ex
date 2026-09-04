defmodule Cairn.SnapshotHelpers do
  @moduledoc """
  Adds camera ids to the application config server's published snapshot for
  the rest of the test.

  `Cairn.CameraStatus` and `Cairn.CameraControl` refuse a write for a camera
  that snapshot does not name, so a suite whose camera exists only as a
  fixture would have its writes dropped on the floor. Lending the id is the
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
    present = MapSet.new(config.cameras ++ config.dormant, & &1.id)

    # Append, and drop ids the snapshot already names: a real camera stays
    # authoritative for `snapshot_camera/2`, and lending its id is a no-op
    # rather than a placeholder that shadows it.
    lent =
      ids
      |> List.wrap()
      |> Enum.reject(&MapSet.member?(present, &1))
      |> Enum.map(&%Cairn.Config.Camera{id: &1})

    :persistent_term.put(key, %{config | cameras: config.cameras ++ lent})

    # Reverse-order on_exit, so nested lends unwind to what each one found.
    ExUnit.Callbacks.on_exit(fn ->
      if restore, do: :persistent_term.put(key, restore), else: :persistent_term.erase(key)
    end)

    :ok
  end
end
