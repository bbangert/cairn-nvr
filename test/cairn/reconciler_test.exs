defmodule Cairn.ReconcilerTest do
  # The track half of boot reconciliation. The event/filesystem half is covered
  # where its writers are (`Cairn.DataDirTest`, `Cairn.EventExtractorTest`);
  # this is about the rows nothing on disk can speak for.
  use Cairn.DataCase, async: false

  alias Cairn.{Config, DataDir, Event, Events, Reconciler, Tracks}

  setup do
    dir = Path.join(System.tmp_dir!(), "cairn_reconcile_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join([dir, "events"]))
    on_exit(fn -> File.rm_rf(dir) end)
    %{config: %Config{data_dir: dir}}
  end

  defp seed_track(attrs) do
    row =
      Map.merge(
        %{
          id: Cairn.ULID.generate(),
          camera_id: "cam_reconcile",
          started_at: DateTime.add(DateTime.utc_now(), -60),
          label: "person",
          best_score: 0.8,
          source: :host
        },
        attrs
      )

    {:ok, _} = Tracks.insert_batch([{row, []}])
    row.id
  end

  test "closes every track row a dead host left live", %{config: config} do
    # The row a crash leaves behind: opened while the object was in frame, never
    # closed, because only the recorder that opened it ever would have.
    live = seed_track(%{ended_at: nil, end_reason: nil})
    ended_at = DateTime.add(DateTime.utc_now(), -30)
    closed = seed_track(%{ended_at: ended_at, end_reason: :unseen})
    was = Tracks.get(live)

    assert %{tracks_closed: 1} = Reconciler.run(config)

    row = Tracks.get(live)
    assert row.end_reason == :host_restart
    # dated from the row itself — the last instant it was known live — and not
    # from this boot's clock
    assert row.ended_at == was.updated_at

    # a row that closed itself is not touched
    untouched = Tracks.get(closed)
    assert untouched.end_reason == :unseen
    assert DateTime.compare(untouched.ended_at, ended_at) == :eq
  end

  # The node-restart leg of the presence lane's recovery. `Cairn.PresenceCheckpoint`
  # is ETS and dies with the VM, so nothing re-attaches to a tier-1 event that
  # was open at the crash — this does, and it needs nothing lane-specific to:
  # a presence-born row is an ordinary event row (D-E7), differing only in
  # carrying no object ids.
  test "marks a presence-born active row partial when its clip survived", %{config: config} do
    camera_id = "cam_presence_reconcile"

    event = %Event{
      id: Ecto.UUID.generate(),
      camera_id: camera_id,
      started_at: DateTime.add(DateTime.utc_now(), -60),
      status: :active,
      labels: [%{t: +0.0, label: "person", score: 0.9, object_id: nil}],
      max_scores: %{"person" => 0.9},
      max_score: 0.9
    }

    path =
      DataDir.event_clip_path(
        config.data_dir,
        camera_id,
        event.id,
        DateTime.to_unix(event.started_at)
      )

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "clip bytes")
    {:ok, _row} = Events.create_active(event, path)

    assert %{partialed: 1, adopted: 0, deleted: 0} = Reconciler.run(config)

    row = Events.get(event.id)
    assert row.status == :partial
    assert row.bytes == byte_size("clip bytes")
  end

  test "a second run closes nothing, and the summary says so", %{config: config} do
    seed_track(%{ended_at: nil, end_reason: nil})

    assert %{tracks_closed: 1} = Reconciler.run(config)
    assert %{tracks_closed: 0} = Reconciler.run(config)
  end
end
