defmodule Cairn.RepoMigrationTest do
  use Cairn.DataCase, async: true

  test "events table exists with expected columns" do
    columns =
      Repo.query!("PRAGMA table_info(events)").rows
      |> Enum.map(fn [_cid, name | _] -> name end)
      |> MapSet.new()

    expected =
      ~w(id camera_id started_at ended_at status path bytes labels max_score snapshot_path)

    assert Enum.all?(expected, &MapSet.member?(columns, &1))
  end

  test "expected indexes exist" do
    index_names =
      Repo.query!("PRAGMA index_list(events)").rows
      |> Enum.map(fn [_seq, name | _] -> name end)

    assert "events_camera_id_started_at_index" in index_names
    assert "events_status_index" in index_names
  end
end
