defmodule Cairn.ReconcilerTest do
  # The track half of boot reconciliation. The event/filesystem half is covered
  # where its writers are (`Cairn.DataDirTest`, `Cairn.EventExtractorTest`);
  # this is about the rows nothing on disk can speak for.
  use Cairn.DataCase, async: false

  alias Cairn.{Config, Reconciler, Tracks}

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

  test "a second run closes nothing, and the summary says so", %{config: config} do
    seed_track(%{ended_at: nil, end_reason: nil})

    assert %{tracks_closed: 1} = Reconciler.run(config)
    assert %{tracks_closed: 0} = Reconciler.run(config)
  end
end
