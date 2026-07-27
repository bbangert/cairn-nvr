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

  test "the camera_status frame carries the plugin's own reported state" do
    assert {:ok, frame} =
             SSE.frame_for(
               {:camera_status, "cam_a",
                %{
                  status: :running,
                  probe: nil,
                  plugin_status: %{"state" => "degraded", "detail" => "decoder fallback"}
                }}
             )

    assert frame =~ ~s("plugin_status":{)
    assert frame =~ ~s("state":"degraded")
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

defmodule CairnWeb.Api.EventStreamEndpointTest do
  # async: false — drives the global Cairn.CameraStatus and its PubSub topic
  use CairnWeb.ConnCase, async: false

  @token "test-ha-token"

  # The controller loop stops on `{:plug_conn, :sent}`, which is how the test
  # adapter reports a response to the conn's *owner*. Building the conn here
  # and running the endpoint in a task keeps the test process as that owner:
  # the message becomes this test's "the stream is open, and it subscribed"
  # barrier, and the loop only ends when we send it one ourselves.
  test "a plugin status reaches the live SSE endpoint as a camera_status frame" do
    id = "sse_#{System.unique_integer([:positive])}"
    on_exit(fn -> Cairn.CameraStatus.prune(Map.keys(Cairn.CameraStatus.all()) -- [id]) end)

    conn = build_conn(:get, "/api/stream?access_token=#{@token}")
    stream = Task.async(fn -> CairnWeb.Endpoint.call(conn, []) end)

    assert_receive {:plug_conn, :sent}, 5_000

    Cairn.CameraStatus.set_plugin_status(id, %{"state" => "degraded", "detail" => "cpu fallback"})
    # the cast, and the broadcast inside it, are done once the server's mailbox
    # flushes — so the frame is in the stream's mailbox ahead of the stop below
    _ = :sys.get_state(Cairn.CameraStatus)
    send(stream.pid, {:plug_conn, :sent})

    body = Task.await(stream, 5_000).resp_body

    assert body =~ ": connected\n\n"
    assert body =~ "event: camera_status\n"
    assert body =~ ~s("camera_id":"#{id}")
    assert body =~ ~s("plugin_status":{)
    assert body =~ ~s("state":"degraded")
    assert body =~ ~s("detail":"cpu fallback")
  end
end
