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

  test "cameras table exists with expected columns and index" do
    columns =
      Repo.query!("PRAGMA table_info(cameras)").rows
      |> Enum.map(fn [_cid, name | _] -> name end)
      |> MapSet.new()

    expected = ~w(id position enabled settings zones inserted_at updated_at)

    assert Enum.all?(expected, &MapSet.member?(columns, &1))

    index_names =
      Repo.query!("PRAGMA index_list(cameras)").rows
      |> Enum.map(fn [_seq, name | _] -> name end)

    assert "cameras_position_index" in index_names
  end

  test "settings table exists with expected columns" do
    columns =
      Repo.query!("PRAGMA table_info(settings)").rows
      |> Enum.map(fn [_cid, name | _] -> name end)
      |> MapSet.new()

    assert Enum.all?(~w(key value), &MapSet.member?(columns, &1))
  end
end
