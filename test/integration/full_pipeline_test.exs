defmodule Cairn.FullPipelineTest do
  @moduledoc """
  The regression net for the whole pipeline: a real ffmpeg reading a committed
  fixture in a realtime loop (`file://` camera), the mock plugin replaying a
  detection timeline over a real Port, the camera's own tracker, a real extractor
  writing to a tmp data dir, and the events index.

  Twice, over two fixtures that differ in one thing: whether a fragment can
  begin part-way through a GOP. Everything else about the two runs is the same
  camera, plugin and config.

  Excluded by default (`test_helper.exs`); run with
  `mix test --include integration`.
  """

  use Cairn.DataCase, async: false

  @moduletag :integration
  @moduletag timeout: 120_000

  alias Cairn.Config.Camera
  alias Cairn.{Config, Event, Events}

  @fixture Path.absname("test/support/fixtures/media/testsrc_long.fmp4")
  # Same source, GOP three times the muxer's `-frag_duration`: through the
  # production `+frag_keyframe` output that yields alternating 2000/1000 ms
  # fragments of which only every other one opens a GOP — the camera2 shape.
  # `testsrc_long.fmp4`'s GOP is shorter than a fragment, so every fragment of
  # it is keyframe-headed and the `start_time` assertion below can never fail
  # on it however the drain lands.
  @mid_gop_fixture Path.absname("test/support/fixtures/media/testsrc_gop3.fmp4")
  @mock Path.absname("priv/plugins/mock/mock_plugin.exs")

  setup do
    dir = Path.join(System.tmp_dir!(), "cairn_e2e_#{System.unique_integer([:positive])}")
    Cairn.DataDir.ensure!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    timeline = Path.join(dir, "timeline.json")

    File.write!(
      timeline,
      Jason.encode!([
        %{
          at_ms: 8_000,
          pts: 90_000,
          dets: [%{label: "person", score: 0.9, bbox: [0.1, 0.1, 0.2, 0.4]}]
        },
        %{
          at_ms: 9_000,
          pts: 180_000,
          dets: [%{label: "person", score: 0.95, bbox: [0.15, 0.1, 0.2, 0.4]}]
        }
      ])
    )

    camera = %Camera{
      id: "e2e_cam",
      rtsp_url: "file://" <> @fixture,
      plugin: {:inline, ["elixir", @mock, "--timeline", timeline, "--hold"]},
      min_score: %{"default" => 0.5}
    }

    config = %Config{
      data_dir: dir,
      udp_base_port: 19_500,
      udp_port_range: 10,
      pre_window_seconds: 4,
      post_window_seconds: 3,
      max_event_seconds: 60,
      cameras: [camera]
    }

    %{camera: camera, config: config, dir: dir}
  end

  @tag :integration
  test "fixture-loop camera + mock plugin => finalized, playable, indexed clip",
       %{camera: camera, config: config, dir: dir} do
    Event.subscribe()

    start_supervised!({Cairn.Camera, camera: camera, config: config, index: 0})

    # full lifecycle over the "events" topic
    assert_receive {:event_started, %Event{camera_id: "e2e_cam"} = event}, 30_000
    assert_receive {:event_updated, %Event{camera_id: "e2e_cam"}}, 10_000
    assert_receive {:event_ended, %Event{camera_id: "e2e_cam", status: :finalized}}, 30_000

    # index row finalized with real bytes
    row = wait_until(fn -> match?(%{status: :finalized}, Events.get(event.id)) end, event.id)
    assert row.bytes > 0
    assert row.labels["max_scores"] == %{"person" => 0.95}

    # clip exists under the ACTIVE config's data dir (extractors read
    # Config.Server, not the per-camera-tree config) and box-parses
    on_exit(fn ->
      File.rm(row.path)
      if row.snapshot_path, do: File.rm(row.snapshot_path)
    end)

    active_data_dir = Cairn.Config.Server.get().data_dir
    assert String.starts_with?(row.path, active_data_dir)
    _ = dir

    # remux_clips (default on) rewrites the fragmented clip into a plain mp4
    # with a real moov, so the finalized file must probe as a valid, seekable
    # clip whose duration is true and start offset is zero — the property the
    # concatenated-fragment output could never report.
    {start_time, duration} = probe_format(row.path)

    assert_in_delta start_time, 0.0, 0.001
    assert duration > 0.0

    # snapshot lands async
    row =
      wait_until(
        fn -> (Events.get(event.id) || %{snapshot_path: nil}).snapshot_path end,
        event.id
      )

    assert File.exists?(row.snapshot_path)
  end

  @tag :integration
  test "a camera whose GOP outlives its fragments still yields a clip that starts at zero",
       %{camera: camera, config: config} do
    # The same pipeline over a stream where the drain can land mid-GOP. What
    # the extractor now does about that is unit-tested; what this adds is the
    # real ffmpeg on both ends — the camera's `+frag_keyframe` muxer deciding
    # where fragments break, and `Cairn.ClipRemux`'s `-c copy` deciding what it
    # can carry. A clip that started mid-GOP would come out of that with a
    # leading empty edit, which is exactly what `start_time` reports.
    Event.subscribe()

    camera = %{camera | id: "e2e_gop3", rtsp_url: "file://" <> @mid_gop_fixture}
    config = %{config | cameras: [camera]}

    start_supervised!({Cairn.Camera, camera: camera, config: config, index: 1})

    assert_receive {:event_started, %Event{camera_id: "e2e_gop3"} = event}, 30_000
    assert_receive {:event_ended, %Event{camera_id: "e2e_gop3", status: :finalized}}, 30_000

    row = wait_until(fn -> match?(%{status: :finalized}, Events.get(event.id)) end, event.id)
    assert row.bytes > 0

    on_exit(fn ->
      File.rm(row.path)
      if row.snapshot_path, do: File.rm(row.snapshot_path)
    end)

    refute Cairn.MP4Boxes.leading_empty_edit?(File.read!(row.path))

    {start_time, duration} = probe_format(row.path)

    assert_in_delta start_time, 0.0, 0.001
    assert duration > 0.0

    # Not an assertion about snapshots — it is what keeps the async snapshot
    # task inside the test's sandbox checkout. Returning before it runs rolls
    # the row back underneath it, and it logs a `:not_found` it cannot do
    # anything about.
    row =
      wait_until(
        fn -> (Events.get(event.id) || %{snapshot_path: nil}).snapshot_path end,
        event.id
      )

    assert File.exists?(row.snapshot_path)
  end

  # key=value output: ffprobe prints csv fields in its own fixed order no
  # matter how `-show_entries` orders them, so positional parsing would ride
  # on an ordering nothing here controls.
  defp probe_format(path) do
    {probe, 0} =
      System.cmd(
        "ffprobe",
        ~w(-v error -show_entries format=duration,start_time -of default=noprint_wrappers=1) ++
          [path]
      )

    fields =
      for line <- String.split(String.trim(probe), "\n"), into: %{} do
        [k, v] = String.split(line, "=", parts: 2)
        {k, elem(Float.parse(v), 0)}
      end

    {Map.fetch!(fields, "start_time"), Map.fetch!(fields, "duration")}
  end

  defp wait_until(fun, event_id, attempts \\ 200) do
    cond do
      fun.() ->
        Events.get(event_id)

      attempts == 0 ->
        flunk("condition never became true for event #{event_id}")

      true ->
        Process.sleep(100)
        wait_until(fun, event_id, attempts - 1)
    end
  end
end
