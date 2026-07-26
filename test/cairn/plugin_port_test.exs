defmodule Cairn.PluginPortTest do
  use ExUnit.Case, async: false

  alias Cairn.Config.Camera
  alias Cairn.{DetectionAggregator, Event, PluginPort}

  @mock Path.absname("priv/plugins/mock/mock_plugin.exs")
  @timeline Path.absname("test/support/fixtures/timelines/person_walkthrough.json")

  defp camera(id) do
    %Camera{
      id: id,
      rtsp_url: "rtsp://h/1",
      plugin: {:inline, ["elixir", @mock]},
      min_score: %{"default" => 0.5}
    }
  end

  defp config, do: %Cairn.Config{data_dir: "tmp/plugin_port_test", udp_base_port: 19_100}

  test "build_argv appends contract arguments" do
    argv = PluginPort.build_argv(camera("c"), 17_002)

    assert ["elixir", @mock, "--camera-id", "c", "--udp-port", "17002", "--min-score-json", json] =
             argv

    assert Jason.decode!(json) == %{"default" => 0.5}
  end

  test "mock plugin timeline drives the aggregator through a full Port" do
    id = "plug_#{System.unique_integer([:positive])}"
    test_pid = self()

    agg =
      start_supervised!(
        {DetectionAggregator,
         name: nil,
         start_extractor: fn _camera, _event ->
           {:ok, spawn(fn -> Process.sleep(:infinity) end)}
         end,
         finalize_extractor: fn _pid, event -> send(test_pid, {:finalized, event}) end}
      )

    Event.subscribe()

    command =
      "elixir #{@mock} --camera-id #{id} --udp-port 19100 " <>
        "--min-score-json '{}' --timeline #{@timeline}; sleep 30"

    start_supervised!(
      {PluginPort,
       camera: camera(id), config: config(), index: 0, command: command, aggregator: agg}
    )

    assert_receive {:event_started, %Event{camera_id: ^id} = event}, 5_000
    assert [%{label: "person"}] = event.labels

    # third batch has person (0.93, passes) + cat (0.4, filtered by 0.5 default)
    assert_receive {:event_updated, %Event{camera_id: ^id}}, 5_000
    assert_receive {:event_updated, %Event{camera_id: ^id} = updated}, 5_000
    assert Map.keys(updated.max_scores) == ["person"]
  end

  test "malformed lines are dropped without crashing" do
    id = "plug_#{System.unique_integer([:positive])}"

    agg =
      start_supervised!(
        {DetectionAggregator,
         name: nil,
         start_extractor: fn _c, _e -> {:ok, spawn(fn -> Process.sleep(:infinity) end)} end}
      )

    Event.subscribe()

    command =
      ~s(printf 'garbage\\n{"nope": true}\\n{"pts": 1, "dets": [{"label": "person", "score": 0.9, "bbox": [0,0,1,1]}]}\\n'; sleep 30)

    pid =
      start_supervised!(
        {PluginPort,
         camera: camera(id), config: config(), index: 0, command: command, aggregator: agg}
      )

    assert_receive {:event_started, %Cairn.Event{camera_id: ^id}}, 5_000
    assert Process.alive?(pid)
  end

  test "plugin exit triggers backoff respawn" do
    id = "plug_#{System.unique_integer([:positive])}"

    agg =
      start_supervised!(
        {DetectionAggregator,
         name: nil,
         start_extractor: fn _c, _e -> {:ok, spawn(fn -> Process.sleep(:infinity) end)} end}
      )

    Event.subscribe()

    # exits immediately after one valid line; respawn emits it again
    command =
      ~s(printf '{"pts": 1, "dets": [{"label": "person", "score": 0.9, "bbox": [0,0,1,1]}]}\\n')

    start_supervised!(
      {PluginPort,
       camera: camera(id),
       config: config(),
       index: 0,
       command: command,
       aggregator: agg,
       backoff_min_ms: 50,
       backoff_max_ms: 100}
    )

    assert_receive {:event_started, %Cairn.Event{camera_id: ^id}}, 5_000
    assert_receive {:event_updated, %Cairn.Event{camera_id: ^id}}, 5_000
  end
end
