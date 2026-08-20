defmodule Cairn.SnapshotTest do
  use Cairn.DataCase, async: false

  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias Cairn.{Config, Event, EventArtifact, Events, Snapshot}

  @fixture "test/support/fixtures/media/testsrc.fmp4"

  setup do
    dir = Path.join(System.tmp_dir!(), "cairn_snap_#{System.unique_integer([:positive])}")
    Cairn.DataDir.ensure!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    Event.subscribe()
    %{dir: dir, config: %Config{data_dir: dir, pre_window_seconds: 0}}
  end

  defp insert(trigger, path) do
    event = %Event{
      id: Ecto.UUID.generate(),
      camera_id: "snap_cam",
      started_at: DateTime.utc_now(),
      max_scores: %{"person" => 0.9},
      max_score: 0.9,
      labels: [],
      trigger: trigger
    }

    {:ok, _} = Events.create_active(event, path)
    finalized = %{event | status: :finalized, ended_at: DateTime.utc_now()}
    {:ok, row} = Events.finalize(finalized, File.stat!(path).size)
    row
  end

  test "draws the trigger bbox + label and seeks to its moment", %{dir: dir, config: config} do
    trigger = %{t: 0.0, label: "person", score: 0.9, bbox: [0.2, 0.2, 0.3, 0.4]}
    row = insert(trigger, @fixture)

    # arg-level: box + label filter present at the given seek
    out = Path.join(Cairn.DataDir.snapshots_dir(dir), "#{row.id}.jpg")
    args = Snapshot.args(row, out, 0.0)
    assert "-vf" in args
    vf = Enum.at(args, Enum.find_index(args, &(&1 == "-vf")) + 1)
    assert vf =~ "drawbox="
    assert vf =~ "drawtext="
    assert Enum.at(args, Enum.find_index(args, &(&1 == "-ss")) + 1) == "0.0000"

    # runs for real and produces a valid image with the overlay baked in
    assert :ok = Snapshot.take(row, config)
    assert File.exists?(out)
    assert File.stat!(out).size > 0

    assert {codec, 0} =
             System.cmd(
               "ffprobe",
               ~w(-v error -select_streams v:0
             -show_entries stream=codec_name -of csv=p=0) ++ [out]
             )

    assert String.trim(codec) in ["mjpeg", "jpeg"]
    assert %{snapshot_path: ^out} = Events.get(row.id)

    # the broadcast is the only signal a consumer gets that the jpg is fetchable
    event_id = row.id
    size = File.stat!(out).size

    assert_receive {:event_snapshot_ready,
                    %EventArtifact{
                      event_id: ^event_id,
                      camera_id: "snap_cam",
                      path: ^out,
                      bytes: ^size,
                      reason: nil
                    }}

    refute_received {:event_snapshot_failed, _}
  end

  test "a presence-born trigger draws its box with no object identity",
       %{dir: dir, config: config} do
    # `Cairn.PresenceRecorder`'s trigger shape: the lane runs no tracker, so
    # `object_id` is nil. Nothing on the drawing path reads it — the box, the
    # label and the seek come from `bbox`, `label`/`score` and `t`.
    trigger = %{
      t: 0.0,
      label: "person",
      score: 0.82,
      bbox: [0.3, 0.25, 0.2, 0.3],
      object_id: nil
    }

    row = insert(trigger, @fixture)
    out = Path.join(Cairn.DataDir.snapshots_dir(dir), "#{row.id}.jpg")

    assert Snapshot.clip_seek(row, config) == 0.0
    args = Snapshot.args(row, out, Snapshot.clip_seek(row, config))
    vf = Enum.at(args, Enum.find_index(args, &(&1 == "-vf")) + 1)
    assert vf =~ "drawbox=x=iw*0.3000"
    assert vf =~ ~s(drawtext=text='person 0.8200')

    assert :ok = Snapshot.take(row, config)
    assert File.stat!(out).size > 0
    assert %{snapshot_path: ^out} = Events.get(row.id)

    event_id = row.id
    assert_receive {:event_snapshot_ready, %EventArtifact{event_id: ^event_id}}
  end

  test "a snapshot that produces no output announces its failure", %{config: config} do
    row = insert(nil, @fixture)
    # a clip ffmpeg cannot decode: it writes nothing and still exits 0
    broken = Path.join(config.data_dir, "broken.mp4")
    File.write!(broken, "not an mp4")
    row = %{row | path: broken}

    log = capture_log(fn -> assert :ok = Snapshot.take(row, config) end)
    assert log =~ "snapshot produced no output"
    assert %{snapshot_path: nil} = Events.get(row.id)

    event_id = row.id

    assert_receive {:event_snapshot_failed,
                    %EventArtifact{
                      event_id: ^event_id,
                      camera_id: "snap_cam",
                      path: nil,
                      bytes: nil,
                      reason: :no_output
                    }}

    refute_received {:event_snapshot_ready, _}
  end

  # The silence this phase exists to break: the jpg was written but the row
  # update lost, so `snapshot_url` never resolves and nothing said so.
  test "a snapshot the index will not accept announces its failure", %{config: config} do
    row = insert(nil, @fixture)
    {:ok, _} = Events.delete_row(row)

    log = capture_log(fn -> assert :ok = Snapshot.take(row, config) end)
    assert log =~ "snapshot not recorded"

    event_id = row.id

    assert_receive {:event_snapshot_failed,
                    %EventArtifact{event_id: ^event_id, camera_id: "snap_cam", reason: :not_found}}

    refute_received {:event_snapshot_ready, _}
  end

  # `:exception` is the catch-all reason, and it has two independent windows:
  # the ffmpeg side and the index side. Neither may end in silence, and the
  # index side must not contradict a `_ready` that already went out.
  test "a snapshot whose ffmpeg call blows up announces :exception", %{config: config} do
    row = insert(nil, @fixture)
    # no clip path: the argv is malformed and System.cmd raises
    row = %{row | path: nil}

    log = capture_log(fn -> assert :ok = Snapshot.take(row, config) end)
    assert log =~ "snapshot error"

    event_id = row.id

    assert_receive {:event_snapshot_failed,
                    %EventArtifact{
                      event_id: ^event_id,
                      camera_id: "snap_cam",
                      path: nil,
                      bytes: nil,
                      reason: :exception
                    }}

    refute_received {:event_snapshot_ready, _}
  end

  test "a jpg the index call blows up on announces :exception, never ready", %{config: config} do
    row = insert(nil, @fixture)
    # the jpg is written, then the index call raises on the way in — a
    # stand-in for anything Ecto throws once ffmpeg has already succeeded
    row = %{row | id: 42}

    log = capture_log(fn -> assert :ok = Snapshot.take(row, config) end)
    assert log =~ "snapshot not recorded"

    assert_receive {:event_snapshot_failed, %EventArtifact{reason: :exception}}
    refute_received {:event_snapshot_ready, _}
  end

  test "seek is clamped inside the clip so a short clip still yields a frame",
       %{dir: dir, config: config} do
    # a trigger far past the tiny fixture's duration must not seek past the end
    row = insert(%{t: 999.0, label: "car", score: 0.8, bbox: [0.1, 0.1, 0.2, 0.2]}, @fixture)
    out = Path.join(Cairn.DataDir.snapshots_dir(dir), "#{row.id}.jpg")

    assert :ok = Snapshot.take(row, config)
    assert File.exists?(out)
    assert File.stat!(out).size > 0
  end

  test "no trigger falls back to first frame, no overlay", %{config: config} do
    row = insert(nil, @fixture)
    args = Snapshot.args(row, "x.jpg", nil)
    refute "-vf" in args
    refute "-ss" in args
    assert :ok = Snapshot.take(row, config)
    assert %{snapshot_path: p} = Events.get(row.id)
    assert File.exists?(p)
  end

  test "clamps an out-of-frame bbox into 0..1", _ctx do
    row = insert(%{t: 0.0, label: "person", score: 0.9, bbox: [0.9, 0.9, 0.5, 0.5]}, @fixture)
    vf = Snapshot.args(row, "x.jpg", 0.0) |> Enum.at(-2)
    # x=0.9 leaves at most 0.1 width; height likewise
    assert vf =~ "w=iw*0.1000"
    assert vf =~ "h=ih*0.1000"
  end

  test "a malformed bbox falls back to the first frame, not no snapshot", %{config: config} do
    # a list bbox of the wrong shape must not reach clamp_bbox and raise
    row = insert(%{t: 0.0, label: "person", score: 0.9, bbox: [0.1, 0.2]}, @fixture)
    args = Snapshot.args(row, "x.jpg", nil)
    refute "-vf" in args
    assert :ok = Snapshot.take(row, config)
    assert %{snapshot_path: p} = Events.get(row.id)
    assert File.exists?(p)
  end

  describe "clip_seek/2" do
    # Lifted from a real reolink event. The drain returned 36 ms *after* the
    # event's own start and had drained 1000 ms of pre-roll, so the event's
    # t=0 sits 0.964 s into the clip — not the 1.0 s the config promised. Every
    # expected value below is written out by hand rather than recomputed from
    # these, so that an arithmetic slip in `clip_seek/2` cannot slip through
    # the test with it.
    @span_ms 1_000
    @wall_ms 1_785_597_751_542
    @started_ms 1_785_597_751_506
    @anchor %{
      first_pts: 0,
      timescale: 90_000,
      drained_span_ms: @span_ms,
      drain_wall_ms: @wall_ms,
      event_started_ms: @started_ms
    }
    # No live half at all — the shape every sidecar written before it existed
    # has, and the shape an event that finalized before a fragment arrived
    # still has. Which makes the drain-half expectations below the
    # old-file-compatibility test as much as anything.
    #
    # The live half of the same event: a fragment reached the extractor 1_700 ms
    # after the drain returned, ending 3_000 ms into the clip's media — 1_000 ms
    # drained plus its own 2_000. It places the event's t=0 at 1.264 s rather
    # than the drain half's 0.964, and that 300 ms is the fragment ffmpeg had
    # not written out when the drain was taken.
    @live_anchor Map.merge(@anchor, %{live_media_ms: 3_000, live_wall_ms: 1_785_597_753_242})
    @trig %{t: 0.75, label: "person", score: 0.9, bbox: [0.2, 0.2, 0.3, 0.4]}

    # The fixture is 6.0 s long, so the clamp sits at 5.8 and none of the
    # expectations below reach it — except the one that means to.
    defp clip(dir) do
      path = Path.join(dir, "clip.mp4")
      File.cp!(@fixture, path)
      path
    end

    defp sidecar!(path, anchor) do
      bytes = Cairn.TrackPath.encode(%{event_id: "e", camera_id: "snap_cam", anchor: anchor}, [])
      File.write!(Cairn.DataDir.trackpath_for_clip(path), bytes)
    end

    # 1.0 s of configured pre-roll: distinct from the 0.964 s the anchor
    # measures, so which of the two answered is visible in the result.
    defp seek_config(config), do: %{config | pre_window_seconds: 1.0}

    test "the anchor's drain half places the seek when it is all there is", ctx do
      path = clip(ctx.dir)
      sidecar!(path, @anchor)
      row = insert(@trig, path)

      # (1000 + 1785597751506 − 1785597751542) / 1000 + 0.75
      assert Snapshot.clip_seek(row, seek_config(ctx.config)) == 1.714
    end

    test "the live half is preferred over the drain half", ctx do
      path = clip(ctx.dir)
      sidecar!(path, @live_anchor)
      row = insert(@trig, path)

      # (3000 + 1785597751506 − 1785597753242) / 1000 + 0.75 — 300 ms later
      # than the drain half's answer, and 300 ms is what the drain could not
      # see. The poster frame moves with the boxes or it stops matching them.
      assert Snapshot.clip_seek(row, seek_config(ctx.config)) == 2.014
    end

    test "a live half that cannot place the trigger leaves the drain half to", ctx do
      path = clip(ctx.dir)
      # An ffmpeg respawn under the anchor: pts restarted, the extractor's
      # subtraction went negative, and the media position is not one.
      sidecar!(path, %{@live_anchor | live_media_ms: -4_000})
      row = insert(@trig, path)

      assert Snapshot.clip_seek(row, seek_config(ctx.config)) == 1.714
    end

    test "no sidecar falls back to the configured pre-window", ctx do
      row = insert(@trig, clip(ctx.dir))

      # 1.0 + 0.75, the approximation, and 36 ms off the anchor's answer
      assert Snapshot.clip_seek(row, seek_config(ctx.config)) == 1.75
    end

    test "a file that is not a sidecar falls back", ctx do
      path = clip(ctx.dir)
      File.write!(Cairn.DataDir.trackpath_for_clip(path), "not gzip, not msgpack")
      row = insert(@trig, path)

      assert Snapshot.clip_seek(row, seek_config(ctx.config)) == 1.75
    end

    test "a sidecar with no anchor at all falls back", ctx do
      path = clip(ctx.dir)
      sidecar!(path, nil)
      row = insert(@trig, path)

      assert Snapshot.clip_seek(row, seek_config(ctx.config)) == 1.75
    end

    # The header type allows every anchor field to be nil on its own, so an
    # anchor whose media fields were captured and whose wall-clock ones were
    # not is a shape this has to survive rather than divide by.
    test "an anchor missing the wall-clock fields falls back", ctx do
      path = clip(ctx.dir)
      sidecar!(path, %{first_pts: 0, timescale: 90_000})
      row = insert(@trig, path)

      assert Snapshot.clip_seek(row, seek_config(ctx.config)) == 1.75
    end

    # A sidecar from another clip, or a trigger from before the drain: the
    # anchor is well-formed and the answer is still not a position in this
    # file. Better the estimate than a seek ffmpeg reads as 0.
    test "an anchor that places the trigger before the clip falls back", ctx do
      path = clip(ctx.dir)
      sidecar!(path, %{@anchor | drain_wall_ms: @started_ms + 30_000})
      row = insert(@trig, path)

      assert Snapshot.clip_seek(row, seek_config(ctx.config)) == 1.75
    end

    test "the anchored seek is clamped inside the clip like the estimate", ctx do
      path = clip(ctx.dir)
      sidecar!(path, %{@anchor | drained_span_ms: 60_000})
      row = insert(@trig, path)

      # 60.714 would land past the end of a 6.0 s clip and write nothing
      assert Snapshot.clip_seek(row, seek_config(ctx.config)) == 5.8
    end

    # A presence-born trigger whose detection sat in the pre-roll. The estimate
    # counts from the clip's first sample, so a negative offset is a position
    # inside the pre-window rather than something to throw away.
    test "a negative trigger time seeks back into the pre-roll", ctx do
      row = insert(%{@trig | t: -0.4}, clip(ctx.dir))

      # 1.0 - 0.4
      assert Snapshot.clip_seek(row, seek_config(ctx.config)) == 0.6
    end

    # The pre-roll actually retained can be shorter than the configured one —
    # an unfilled ring, or the extractor cutting back to its first keyframe —
    # so the estimate can point before the clip even exists.
    test "a trigger older than the whole pre-window floors at the clip's start", ctx do
      row = insert(%{@trig | t: -2.5}, clip(ctx.dir))

      # 1.0 - 2.5 is -1.5, which is not a position in any file
      assert Snapshot.clip_seek(row, seek_config(ctx.config)) == 0.0
    end

    test "no trigger means no seek, sidecar or not", ctx do
      path = clip(ctx.dir)
      sidecar!(path, @anchor)
      row = insert(nil, path)

      assert Snapshot.clip_seek(row, seek_config(ctx.config)) == nil
    end
  end

  test "draws the box but no label when no font is available", %{config: config} do
    Application.put_env(:cairn, :snapshot_font, "/no/such/font.ttf")
    on_exit(fn -> Application.delete_env(:cairn, :snapshot_font) end)

    row = insert(%{t: 0.0, label: "person", score: 0.9, bbox: [0.2, 0.2, 0.3, 0.4]}, @fixture)
    out = Path.join(Cairn.DataDir.snapshots_dir(config.data_dir), "#{row.id}.jpg")

    vf = Snapshot.args(row, out, 0.0) |> Enum.at(-2)
    assert vf =~ "drawbox="
    refute vf =~ "drawtext="

    # still produces a valid image, just without the label
    assert :ok = Snapshot.take(row, config)
    assert File.stat!(out).size > 0
  end
end
