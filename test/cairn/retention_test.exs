defmodule Cairn.RetentionTest do
  use Cairn.DataCase, async: false

  alias Cairn.Config.Camera
  alias Cairn.{Config, Event, Events, Retention, Tracks}

  setup do
    dir = Path.join(System.tmp_dir!(), "cairn_ret_#{System.unique_integer([:positive])}")
    Cairn.DataDir.ensure!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    %{dir: dir}
  end

  defp config(dir, cameras \\ []) do
    %Config{
      data_dir: dir,
      retention_days: 7,
      retention_per_label: %{"person" => 30},
      free_space_min_mb: 100,
      cameras: cameras
    }
  end

  defp seed_event(dir, camera_id, days_ago, labels) do
    id = Ecto.UUID.generate()
    started = DateTime.add(DateTime.utc_now(), -days_ago * 86_400)
    path = Cairn.DataDir.event_clip_path(dir, camera_id, id, DateTime.to_unix(started))
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "clip")
    snapshot = Path.join(Cairn.DataDir.snapshots_dir(dir), "#{id}.jpg")
    File.write!(snapshot, "jpg")

    event = %Event{
      id: id,
      camera_id: camera_id,
      started_at: started,
      max_scores: Map.new(labels, &{&1, 0.9})
    }

    {:ok, _row} = Events.create_active(event, path)
    {:ok, row} = Events.finalize(%{event | ended_at: started, status: :finalized}, 4)
    {:ok, row} = Events.set_snapshot(row.id, snapshot)
    row
  end

  # `ended_days_ago` nil is a live track: still running, never ended.
  defp seed_track(started_days_ago, ended_days_ago) do
    now = DateTime.utc_now()
    id = Cairn.ULID.generate()
    started = DateTime.add(now, -started_days_ago * 86_400)
    ended = ended_days_ago && DateTime.add(now, -ended_days_ago * 86_400)

    {:ok, _counts} =
      Tracks.insert_batch([
        {%{
           id: id,
           camera_id: "c1",
           started_at: started,
           ended_at: ended,
           label: "person",
           source: :host,
           end_reason: ended && :unseen
         }, [%{at: started, kind: :appeared, bbox: [1, 2, 3, 4]}]}
      ])

    id
  end

  test "prune respects per-label overrides (max wins) and camera overrides", %{dir: dir} do
    cam = %Camera{id: "c1", rtsp_url: "r", retention_days: 2}
    cfg = config(dir, [cam])

    old_plain = seed_event(dir, "c1", 3, ["car"])
    fresh_plain = seed_event(dir, "c1", 1, ["car"])
    old_person = seed_event(dir, "other", 10, ["person", "car"])
    other_cam = seed_event(dir, "other", 10, ["car"])

    assert Retention.run_prune(cfg) == 2

    # camera retention 2d: 3d-old car event pruned, files gone
    assert Events.get(old_plain.id) == nil
    refute File.exists?(old_plain.path)
    refute File.exists?(old_plain.snapshot_path)

    assert Events.get(fresh_plain.id)
    # global person override (30d) outweighs the global 7d default;
    # max across labels wins for multi-label events
    assert Events.get(old_person.id)
    # unconfigured camera falls back to global 7d
    assert Events.get(other_cam.id) == nil
  end

  test "prune expires tracks past tracks_days, moments with them", %{dir: dir} do
    cfg = %{config(dir) | retention_tracks_days: 30}
    old = seed_track(41, 40)

    Retention.run_prune(cfg)

    assert Tracks.get(old) == nil
    assert Tracks.moments(old) == []
  end

  test "prune keeps tracks inside tracks_days, and live tracks of any age", %{dir: dir} do
    cfg = %{config(dir) | retention_tracks_days: 30}
    # inside the track clock, but far outside the 7d event clock the same pass
    # applies to clips — the two are independent
    recent = seed_track(21, 20)
    ancient_live = seed_track(400, nil)

    Retention.run_prune(cfg)

    assert Tracks.get(recent)
    assert Tracks.get(ancient_live)
  end

  test "emergency cleanup deletes every event before it touches a track", %{dir: dir} do
    cfg = config(dir)
    event = seed_event(dir, "c1", 5, ["car"])
    track = seed_track(400, 400)

    # never satisfied while any event remains: the sweep runs the index dry
    free_fun = fn _dir ->
      if Events.all() == [], do: {:ok, 500 * 1024 * 1024}, else: {:ok, 10 * 1024 * 1024}
    end

    ret =
      start_supervised!(
        {Retention, name: nil, manual: true, config_fun: fn -> cfg end, free_space_fun: free_fun}
      )

    Retention.subscribe()
    send(ret, :emergency)

    assert_receive {:disk_alert, %{active: true}}, 2_000
    wait_until(fn -> Events.get(event.id) == nil end)

    # older than everything the sweep deleted, and still here
    assert Tracks.get(track)
    assert Tracks.moments(track) != []
  end

  test "emergency cleanup deletes oldest until above threshold and alerts", %{dir: dir} do
    cfg = config(dir)

    oldest = seed_event(dir, "c1", 5, ["car"])
    middle = seed_event(dir, "c1", 3, ["car"])
    newest = seed_event(dir, "c1", 1, ["car"])

    test_pid = self()
    calls = :counters.new(1, [])

    # low free space until 2 deletions have happened
    free_fun = fn _dir ->
      :counters.add(calls, 1, 1)
      remaining = Events.all() |> length()
      if remaining > 1, do: {:ok, 10 * 1024 * 1024}, else: {:ok, 500 * 1024 * 1024}
    end

    ret =
      start_supervised!(
        {Retention, name: nil, manual: true, config_fun: fn -> cfg end, free_space_fun: free_fun}
      )

    Retention.subscribe()
    send(ret, :emergency)

    assert_receive {:disk_alert, %{active: true}}, 2_000

    # oldest two deleted, newest survives
    wait_until(fn -> Events.get(oldest.id) == nil end)
    assert Events.get(middle.id) == nil
    assert Events.get(newest.id)
    refute File.exists?(oldest.path)

    # recovery clears the alert
    send(ret, :emergency)
    assert_receive {:disk_alert, %{active: false}}, 2_000
    assert Retention.alert(ret) == %{active: false, free_mb: 500, threshold_mb: 100}
    _ = test_pid
  end

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition never became true")

      true ->
        Process.sleep(10)
        wait_until(fun, attempts - 1)
    end
  end
end
