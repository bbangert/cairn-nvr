defmodule Cairn.DetectionAggregatorControlTest do
  # verifies runtime CameraControl toggles change aggregator behavior
  use ExUnit.Case, async: false

  alias Cairn.{CameraControl, DetectionAggregator, Event, EventCheckpoint, Observation}
  alias Cairn.Config.Camera

  @windows %{pre: 5, post: 10, max: 300}

  setup do
    camera_id = "aggc_#{System.unique_integer([:positive])}"
    camera = %Camera{id: camera_id, rtsp_url: "rtsp://h/1", min_score: %{"default" => 0.5}}
    test_pid = self()

    agg =
      start_supervised!(
        {DetectionAggregator,
         name: nil,
         start_extractor: fn _camera, event ->
           pid = spawn(fn -> Process.sleep(:infinity) end)
           send(test_pid, {:extractor_started, event, pid})
           {:ok, pid}
         end,
         finalize_extractor: fn pid, event ->
           send(test_pid, {:extractor_finalized, pid, event})
         end}
      )

    Event.subscribe()
    on_exit(fn -> EventCheckpoint.delete(camera_id) end)

    %{agg: agg, camera: camera, camera_id: camera_id}
  end

  defp detect(agg, camera, score \\ 0.9) do
    observation = %Observation{
      pts: 90_000,
      observed_at: DateTime.utc_now(),
      objects: [
        %{
          label: "person",
          score: score,
          bbox: [0.1, 0.1, 0.2, 0.4],
          track_id: nil,
          observation_kind: "detected"
        }
      ]
    }

    DetectionAggregator.detections(agg, camera, @windows, observation)
  end

  # `detections/4` is an async cast; flushing the aggregator's mailbox with
  # :sys.get_state guarantees it (and its synchronous PubSub broadcast) is done,
  # so we can assert "no event" with no timing window.
  defp refute_event_started(agg) do
    :sys.get_state(agg)
    refute_received {:event_started, _}
  end

  test "detection_enabled=false drops batches — no event starts", ctx do
    CameraControl.set(ctx.camera_id, %{detection_enabled: false})

    detect(ctx.agg, ctx.camera)

    refute_event_started(ctx.agg)
  end

  test "recording_enabled=false suppresses event start", ctx do
    CameraControl.set(ctx.camera_id, %{recording_enabled: false})

    detect(ctx.agg, ctx.camera)

    refute_event_started(ctx.agg)
  end

  test "min_score override raises the threshold", ctx do
    CameraControl.set(ctx.camera_id, %{min_score: 0.95})

    # 0.9 is above the configured 0.5 but below the 0.95 override → filtered out
    detect(ctx.agg, ctx.camera, 0.9)
    refute_event_started(ctx.agg)

    # above the override → passes
    detect(ctx.agg, ctx.camera, 0.99)
    assert_receive {:event_started, %Event{camera_id: cid}}
    assert cid == ctx.camera_id
  end

  test "defaults (no control set) behave exactly as configured", ctx do
    detect(ctx.agg, ctx.camera, 0.9)
    assert_receive {:event_started, %Event{camera_id: cid}}
    assert cid == ctx.camera_id
  end
end
