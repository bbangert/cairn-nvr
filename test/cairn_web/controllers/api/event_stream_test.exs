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

  describe "track lifecycle frames" do
    defp track do
      %Cairn.Track{
        object_id: "01J8ZQ0P8B7X0N2R4C6D8E0F2G",
        camera_id: "cam_a",
        label: "person",
        score: 0.81,
        best_score: 0.9,
        bbox: [0.1, 0.1, 0.2, 0.4],
        source: :plugin,
        plugin_track_id: "t1",
        epoch: "01J8ZQ0P8B7X0N2R4C6D8E0F2G",
        started_at: ~U[2026-07-24 00:00:00Z],
        last_seen_at: ~U[2026-07-24 00:00:02Z],
        last_detected_at: ~U[2026-07-24 00:00:01Z]
      }
    end

    test "started and updated carry the full identity" do
      assert {:ok, frame} = SSE.frame_for({:track_started, track()})
      assert frame =~ "event: track_started\n"
      assert frame =~ ~s("object_id":"01J8ZQ0P8B7X0N2R4C6D8E0F2G")
      assert frame =~ ~s("camera_id":"cam_a")
      assert frame =~ ~s("label":"person")
      assert frame =~ ~s("best_score":0.9)
      assert frame =~ ~s("source":"plugin")
      assert frame =~ ~s("plugin_track_id":"t1")
      assert frame =~ ~s("stale_predicted":false)
      assert frame =~ ~s("end_reason":null)
      assert String.ends_with?(frame, "\n\n")

      assert {:ok, updated} = SSE.frame_for({:track_updated, track()})
      assert updated =~ "event: track_updated\n"
    end

    # ONVIF AN §A.10: the final summary stands on its own — a client that
    # missed every other frame still learns what the track was.
    test "the final frame is self-contained and names its end reason" do
      assert {:ok, frame} =
               SSE.frame_for({:track_ended, %{track() | end_reason: :stream_reset}})

      assert frame =~ "event: track_ended\n"
      assert frame =~ ~s("end_reason":"stream_reset")
      assert frame =~ ~s("label":"person")
      assert frame =~ ~s("started_at":"2026-07-24T00:00:00Z")
      assert frame =~ ~s("last_seen_at":"2026-07-24T00:00:02Z")
    end
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
