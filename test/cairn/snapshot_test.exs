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
