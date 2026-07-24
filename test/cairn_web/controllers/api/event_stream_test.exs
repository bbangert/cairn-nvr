defmodule CairnWeb.Api.EventStreamTest do
  use ExUnit.Case, async: true

  alias CairnWeb.Api.EventStreamController, as: SSE

  test "event lifecycle messages become the right SSE frames without leaking paths" do
    event = %Cairn.Event{
      id: "evt-1",
      camera_id: "cam_a",
      started_at: ~U[2026-07-24 00:00:00Z],
      max_scores: %{"person" => 0.9},
      path: "/data/events/cam_a/evt-1.mp4",
      snapshot_path: "/data/snap/evt-1.jpg"
    }

    assert {:ok, frame} = SSE.frame_for({:event_started, event})
    assert frame =~ "event: event_started\n"
    assert frame =~ ~s("clip_url":"/api/media/events/evt-1")
    # on-disk paths must never appear on the wire
    refute frame =~ "/data/events"
    refute frame =~ "snapshot_path"
    assert String.ends_with?(frame, "\n\n")

    assert {:ok, ended} = SSE.frame_for({:event_ended, event})
    assert ended =~ "event: event_ended\n"
  end

  test "camera_control and camera_status messages map to frames" do
    assert {:ok, ctrl} =
             SSE.frame_for(
               {:camera_control, "cam_a",
                %{detection_enabled: false, recording_enabled: true, min_score: 0.7}}
             )

    assert ctrl =~ "event: camera_control\n"
    assert ctrl =~ ~s("camera_id":"cam_a")

    assert {:ok, status} =
             SSE.frame_for({:camera_status, "cam_a", %{status: :running, probe: nil}})

    assert status =~ "event: camera_status\n"
  end

  test "an error-tuple probe is sanitized rather than crashing the encode" do
    assert {:ok, frame} =
             SSE.frame_for(
               {:camera_status, "cam_a", %{status: :backoff, probe: {:error, :timeout}}}
             )

    assert frame =~ "camera_status"
    assert frame =~ "error"
  end

  test "unknown messages are ignored" do
    assert SSE.frame_for({:something_else, 1}) == :ignore
  end
end
