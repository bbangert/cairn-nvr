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

  describe "presence frames" do
    defp presence(fields) do
      struct!(
        %Cairn.PresenceEvent{
          camera_id: "cam_a",
          zone: nil,
          label: "person",
          score: 0.8,
          first_seen_at: ~U[2026-07-24 00:00:00Z],
          at: ~U[2026-07-24 00:00:03Z]
        },
        fields
      )
    end

    test "presence_started names the state present and carries the transition's fields" do
      assert {:ok, frame} = SSE.frame_for({:presence_started, presence([])})

      assert frame =~ "event: presence_started\n"
      assert frame =~ ~s("camera_id":"cam_a")
      assert frame =~ ~s("zone":null)
      assert frame =~ ~s("label":"person")
      assert frame =~ ~s("state":"present")
      assert frame =~ ~s("score":0.8)
      assert frame =~ ~s("first_seen_at":"2026-07-24T00:00:00Z")
      assert frame =~ ~s("at":"2026-07-24T00:00:03Z")
      assert String.ends_with?(frame, "\n\n")
    end

    test "presence_cleared names the state cleared and keeps the stay's fields" do
      assert {:ok, frame} = SSE.frame_for({:presence_cleared, presence([])})

      assert frame =~ "event: presence_cleared\n"
      assert frame =~ ~s("state":"cleared")
      # The struct's contract: `first_seen_at` survives into the clearing so
      # dwell is readable off this frame alone.
      assert frame =~ ~s("first_seen_at":"2026-07-24T00:00:00Z")
      assert frame =~ ~s("score":0.8)
    end

    test "a zoned transition names the zone the client keys on" do
      assert {:ok, frame} = SSE.frame_for({:presence_started, presence(zone: "drive")})

      assert frame =~ ~s("zone":"drive")
      assert frame =~ ~s("label":"person")
    end

    # The same rule as the artifact key set below: substring assertions
    # cannot catch a stray or a missing key, and D-P4 promises `zone` on
    # every presence frame — whole-frame ones included, where it is `null`
    # rather than absent.
    test "each presence kind emits exactly its own keys, no others" do
      keys = ~w(at camera_id first_seen_at label score state zone)

      for kind <- [:presence_started, :presence_cleared],
          zone <- [nil, "drive"] do
        assert {:ok, frame} = SSE.frame_for({kind, presence(zone: zone)})
        assert [_, json] = Regex.run(~r/^data: (.*)\n\n$/m, frame)
        assert json |> Jason.decode!() |> Map.keys() |> Enum.sort() == keys
      end
    end
  end

  describe "presence-born event frames" do
    # The lifecycle of a tier-1 recording (`Cairn.PresenceRecorder`): the same
    # kinds the tracked lane emits, carrying a trigger nothing assigned an
    # identity to. D-E7 — a client cannot tell the lanes apart, and must not
    # choke on the `null`.
    defp presence_born(fields) do
      struct!(
        %Cairn.Event{
          id: "evt-p1",
          camera_id: "cam_tier1",
          started_at: ~U[2026-07-24 00:00:00Z],
          status: :active,
          labels: [%{t: 0.0, label: "person", score: 0.82, object_id: nil}],
          max_scores: %{"person" => 0.82},
          max_score: 0.82,
          trigger: %{
            t: 1.4,
            label: "person",
            score: 0.82,
            bbox: [0.1, 0.2, 0.3, 0.4],
            object_id: nil
          },
          path: "/data/events/cam_tier1/evt-p1.mp4"
        },
        fields
      )
    end

    test "event_started carries the identity-less trigger and the clip url" do
      assert {:ok, frame} = SSE.frame_for({:event_started, presence_born([])})

      assert frame =~ "event: event_started\n"
      assert frame =~ ~s("camera_id":"cam_tier1")
      assert frame =~ ~s("max_scores":{"person":0.82})
      assert frame =~ ~s("object_id":null)
      assert frame =~ ~s("bbox":[0.1,0.2,0.3,0.4])
      assert frame =~ ~s("clip_url":"/api/media/events/evt-p1")
      refute frame =~ "/data/events"
      assert String.ends_with?(frame, "\n\n")
    end

    test "event_ended is the same frame the tracked lane ends with" do
      ended = presence_born(status: :finalized, ended_at: ~U[2026-07-24 00:00:30Z])

      assert {:ok, frame} = SSE.frame_for({:event_ended, ended})
      assert frame =~ "event: event_ended\n"
      assert frame =~ ~s("status":"finalized")
      assert frame =~ ~s("ended_at":"2026-07-24T00:00:30Z")
    end

    test "an event that never saw a box has a null trigger, not a missing one" do
      assert {:ok, frame} = SSE.frame_for({:event_started, presence_born(trigger: nil)})
      assert frame =~ ~s("trigger":null)
    end
  end

  describe "artifact frames" do
    defp artifact(fields) do
      struct!(%Cairn.EventArtifact{event_id: "evt-1", camera_id: "cam_a"}, fields)
    end

    test "clip_ready carries the fetchable url and the post-remux size" do
      assert {:ok, frame} =
               SSE.frame_for(
                 {:event_clip_ready,
                  artifact(path: "/data/events/cam_a/evt-1.mp4", bytes: 1_234_567)}
               )

      assert frame =~ "event: event_clip_ready\n"
      assert frame =~ ~s("event_id":"evt-1")
      assert frame =~ ~s("camera_id":"cam_a")
      assert frame =~ ~s("bytes":1234567)
      assert frame =~ ~s("clip_url":"/api/media/events/evt-1")
      assert frame =~ ~s("reason":null)
      # the on-disk path is never on the wire
      refute frame =~ "/data/events"
      refute frame =~ "path"
      assert String.ends_with?(frame, "\n\n")
    end

    test "snapshot_ready carries the snapshot url" do
      assert {:ok, frame} =
               SSE.frame_for(
                 {:event_snapshot_ready, artifact(path: "/data/snap/evt-1.jpg", bytes: 4_096)}
               )

      assert frame =~ "event: event_snapshot_ready\n"
      assert frame =~ ~s("snapshot_url":"/api/media/snapshots/evt-1")
      assert frame =~ ~s("bytes":4096)
      refute frame =~ "clip_url"
      refute frame =~ "/data/snap"
    end

    test "failures name the reason and advertise no url" do
      assert {:ok, clip} = SSE.frame_for({:event_clip_failed, artifact(reason: :not_found)})
      assert clip =~ "event: event_clip_failed\n"
      assert clip =~ ~s("reason":"not_found")
      assert clip =~ ~s("clip_url":null)
      assert clip =~ ~s("bytes":null)

      assert {:ok, snap} = SSE.frame_for({:event_snapshot_failed, artifact(reason: :no_output)})
      assert snap =~ "event: event_snapshot_failed\n"
      assert snap =~ ~s("reason":"no_output")
      assert snap =~ ~s("snapshot_url":null)
      assert snap =~ ~s("bytes":null)
    end

    # Substring assertions cannot catch a *stray* key: a clip frame that also
    # carried `snapshot_url` would pass every one of them. The key set is the
    # contract, so assert the key set — for all four kinds.
    test "each kind emits exactly its own keys, no others" do
      base = ~w(bytes camera_id event_id reason)

      for {kind, artifact, url_key} <- [
            {:event_clip_ready, artifact(path: "/x.mp4", bytes: 1), "clip_url"},
            {:event_clip_failed, artifact(reason: :not_found), "clip_url"},
            {:event_snapshot_ready, artifact(path: "/x.jpg", bytes: 1), "snapshot_url"},
            {:event_snapshot_failed, artifact(reason: :no_output), "snapshot_url"}
          ] do
        assert {:ok, frame} = SSE.frame_for({kind, artifact})
        assert [_, json] = Regex.run(~r/^data: (.*)\n\n$/m, frame)
        assert json |> Jason.decode!() |> Map.keys() |> Enum.sort() == Enum.sort([url_key | base])
      end
    end

    # the four kinds only mean anything if they stay apart on the wire
    test "each kind names itself" do
      for kind <- [:event_clip_ready, :event_snapshot_ready] do
        assert {:ok, frame} = SSE.frame_for({kind, artifact(path: "/x", bytes: 1)})
        assert frame =~ "event: #{kind}\n"
      end

      for kind <- [:event_clip_failed, :event_snapshot_failed] do
        assert {:ok, frame} = SSE.frame_for({kind, artifact(reason: :exception)})
        assert frame =~ "event: #{kind}\n"
      end
    end

    test "an artifact struct under an unknown kind is ignored, not crashed on" do
      assert SSE.frame_for({:event_clip_maybe, artifact(bytes: 1)}) == :ignore
    end
  end

  describe "track lifecycle frames" do
    # `source: :plugin` with a `plugin_track_id` on purpose: nothing mints that
    # shape any more (plugin-owned tracking was removed), but rows recorded
    # before the removal still carry it and the frame has to serialize them —
    # which is a stricter test of the shape than two nulls would be.
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
      assert frame =~ ~s("stationary":false)
      assert frame =~ ~s("stationary_since":null)
      assert frame =~ ~s("stationary_ms":0)
      assert frame =~ ~s("end_reason":null)
      assert String.ends_with?(frame, "\n\n")

      assert {:ok, updated} = SSE.frame_for({:track_updated, track()})
      assert updated =~ "event: track_updated\n"
    end

    # The frame a parked object's transition rides out on: the camera tracker gates
    # event evidence on this flag, so a client has to be able to see it.
    test "a stationary track carries the flip and the time it has accrued" do
      parked = %{
        track()
        | stationary: true,
          stationary_since: ~U[2026-07-24 00:00:01Z],
          stationary_ms: 4_000
      }

      assert {:ok, frame} = SSE.frame_for({:track_updated, parked})
      assert frame =~ ~s("stationary":true)
      assert frame =~ ~s("stationary_since":"2026-07-24T00:00:01Z")
      assert frame =~ ~s("stationary_ms":4000)
    end

    # ONVIF AN §A.10: the final summary stands on its own — a client that
    # missed every other frame still learns what the track was.
    test "the final frame is self-contained and names its end reason" do
      final = Cairn.TrackAssertions.assert_self_contained(%{track() | end_reason: :stream_reset})

      assert {:ok, frame} = SSE.frame_for({:track_ended, final})

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
    on_exit(fn -> Cairn.CameraStatus.delete(id) end)

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
