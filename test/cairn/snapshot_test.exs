defmodule Cairn.SnapshotTest do
  use Cairn.DataCase, async: false

  alias Cairn.{Config, Event, Events, Snapshot}

  @fixture "test/support/fixtures/media/testsrc.fmp4"

  setup do
    dir = Path.join(System.tmp_dir!(), "cairn_snap_#{System.unique_integer([:positive])}")
    Cairn.DataDir.ensure!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
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
end
