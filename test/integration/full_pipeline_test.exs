defmodule Cairn.FullPipelineTest do
  @moduledoc """
  The regression net for the whole pipeline: a real ffmpeg reading the
  committed fixture in a realtime loop (`file://` camera), the mock plugin
  replaying a detection timeline over a real Port, the global aggregator,
  a real extractor writing to a tmp data dir, and the events index.

  Excluded by default (`test_helper.exs`); run with
  `mix test --include integration`.
  """

  use Cairn.DataCase, async: false

  @moduletag :integration
  @moduletag timeout: 120_000

  alias Cairn.Config.Camera
  alias Cairn.{Config, Event, Events, MP4.Demuxer}

  @fixture Path.absname("test/support/fixtures/media/testsrc_long.fmp4")
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
      plugin: ["elixir", @mock, "--timeline", timeline, "--hold"],
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
    {_d, events} = Demuxer.push(Demuxer.new("check"), File.read!(row.path))
    assert [{:init, %{codec: "avc1." <> _}} | frags] = events
    assert length(frags) >= 3

    # snapshot lands async
    row =
      wait_until(
        fn -> (Events.get(event.id) || %{snapshot_path: nil}).snapshot_path end,
        event.id
      )

    assert File.exists?(row.snapshot_path)
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
