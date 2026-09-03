defmodule Cairn.RepoMigrationTest do
  # Not async: the data migration below runs through `Ecto.Migrator`, whose
  # queries come from processes this test does not own — only a shared
  # sandbox lends them the connection holding the fixture row.
  use Cairn.DataCase, async: false

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

  # Rows written before `Cairn.Cameras.canonical/1` learned to drop these
  # four still hold them: parse-identical to the absent key, but not
  # byte-identical, so an untouched save would diff and restart the camera.
  # `to:` names the canonicalize migration's own version, not `step: 1`,
  # which assumes it is the newest migration on disk — true today, but a
  # later migration added after it would make `step: 1` down something
  # else's `down` instead. `:to` on the way down runs every migration whose
  # version is *at or above* the target (`Ecto.Migrator`'s
  # `pending_to/4`), so the target has to be the migration's own version —
  # one version earlier (e.g. the prior migration's version) would also
  # catch that one and drop the `cameras` table the fixture rows below
  # need. The canonicalize migration's own `down` is a no-op, so this only
  # puts the version back to pending, which is what lets the fixture rows
  # be written in the old shape.
  #
  # One test, not three: each `Ecto.Migrator` call reloads every migration
  # file, and each reload warns about the module it redefines.
  test "the canonicalize migration strips the parse-identical shapes and keeps the rest" do
    migrate(:down, to: 20_260_903_120_000)

    insert_settings!("old_shape", %{
      "rtsp_url" => "rtsp://h/1",
      "transcode" => false,
      "pipeline" => "membrane",
      "extra_ffmpeg_args" => [],
      "min_score" => %{}
    })

    # `parse/3` reads `transcode` as `… == true`, so a hand-edited string is
    # the default too.
    insert_settings!("string_transcode", %{"rtsp_url" => "rtsp://h/2", "transcode" => "false"})

    # SQLite's JSON has no boolean storage of its own — `1` is the integer
    # form of true, not the JSON `true` the parser reads, and `json_type`
    # (not a value comparison) is what tells them apart.
    insert_settings!("int_transcode", %{"rtsp_url" => "rtsp://h/4", "transcode" => 1})

    # `nil` encodes as JSON `null`, which reads exactly as the absent key.
    insert_settings!("null_transcode", %{"rtsp_url" => "rtsp://h/5", "transcode" => nil})

    kept = %{
      "rtsp_url" => "rtsp://h/3",
      "transcode" => true,
      "pipeline" => "classic",
      "extra_ffmpeg_args" => ["-vf", "scale=640:480"],
      "min_score" => %{"person" => 0.5}
    }

    insert_settings!("kept", kept)

    migrate(:up, all: true)

    assert settings("old_shape") == %{"rtsp_url" => "rtsp://h/1"}
    assert settings("string_transcode") == %{"rtsp_url" => "rtsp://h/2"}
    assert settings("int_transcode") == %{"rtsp_url" => "rtsp://h/4"}
    assert settings("null_transcode") == %{"rtsp_url" => "rtsp://h/5"}
    assert settings("kept") == kept
  end

  defp migrate(direction, opts) do
    Ecto.Migrator.run(
      Repo,
      Ecto.Migrator.migrations_path(Repo),
      direction,
      Keyword.put(opts, :log, false)
    )
  end

  defp insert_settings!(id, settings) do
    Repo.query!(
      """
      INSERT INTO cameras (id, position, enabled, settings, zones, inserted_at, updated_at)
      VALUES (?, 0, 1, ?, '[]', datetime('now'), datetime('now'))
      """,
      [id, Jason.encode!(settings)]
    )
  end

  defp settings(id), do: Repo.get!(Cairn.Cameras.Camera, id).settings

  test "settings table exists with expected columns" do
    columns =
      Repo.query!("PRAGMA table_info(settings)").rows
      |> Enum.map(fn [_cid, name | _] -> name end)
      |> MapSet.new()

    assert Enum.all?(~w(key value), &MapSet.member?(columns, &1))
  end
end
