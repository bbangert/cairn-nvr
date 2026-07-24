defmodule Cairn.DetectionAggregatorControlTest do
  # verifies runtime CameraControl toggles change aggregator behavior
  use ExUnit.Case, async: false

  alias Cairn.{CameraControl, DetectionAggregator, Event, EventCheckpoint}
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
    DetectionAggregator.detections(agg, camera, @windows, 90_000, [
      %{label: "person", score: score, bbox: [0.1, 0.1, 0.2, 0.4]}
    ])
  end

  test "detection_enabled=false drops batches — no event starts", ctx do
    CameraControl.set(ctx.camera_id, %{detection_enabled: false})

    detect(ctx.agg, ctx.camera)

    refute_receive {:event_started, _}, 200
  end

  test "recording_enabled=false suppresses event start", ctx do
    CameraControl.set(ctx.camera_id, %{recording_enabled: false})

    detect(ctx.agg, ctx.camera)

    refute_receive {:event_started, _}, 200
  end

  test "min_score override raises the threshold", ctx do
    CameraControl.set(ctx.camera_id, %{min_score: 0.95})

    # 0.9 is above the configured 0.5 but below the 0.95 override → filtered out
    detect(ctx.agg, ctx.camera, 0.9)
    refute_receive {:event_started, _}, 200

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
