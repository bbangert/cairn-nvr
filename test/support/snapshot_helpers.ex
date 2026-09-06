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

  @doc """
  A `:config_changed` diff's `known` set for a delete of `camera_id` alone.

  The real snapshot minus the id under test is not enough in the full suite:
  every other suite's fixture recorder/tracker is registered too, and a
  `known` that omits them makes this delete look like theirs as well —
  `Cairn.CameraReaper` and `Cairn.EventCheckpoint` stop processes no test
  here is expecting to lose. Adding every currently-registered lane-owner id
  keeps the diff's effect scoped to `camera_id`.
  """
  # `known_ids/0` is `MapSet.t() | nil` (nil = no snapshot published), but these
  # suites run under the application config server, which always has one — so it
  # is a MapSet here. Branching to guard the nil is deliberately avoided: pulling
  # the MapSet out of that union trips dialyzer's opaque-type check, and the nil
  # arm is unreachable in this context anyway.
  @spec known_ids_excluding(String.t()) :: MapSet.t(String.t())
  def known_ids_excluding(camera_id) do
    Cairn.Config.Server.known_ids()
    |> MapSet.union(MapSet.new(registered_lane_owner_ids()))
    |> MapSet.delete(camera_id)
  end

  # Camera ids currently registered under a lane-owner role, deduplicated.
  # Only this helper needs the union, so the reader lives here rather than on
  # `Cairn.Registry`.
  defp registered_lane_owner_ids do
    [:presence_recorder, :camera_tracker]
    |> Enum.flat_map(&Cairn.Registry.ids_for_role/1)
    |> Enum.uniq()
  end
end
