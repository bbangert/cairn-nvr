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
  # async: false — drives the global Cairn.CameraStatus and its PubSub topic,
  # the application's Config.Server and its fixture file, and the limiter
  use CairnWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Cairn.Config.Server
  alias CairnWeb.Api.EventStreamController
  alias CairnWeb.Api.StreamLimiter

  @token "test-ha-token"
  @fixture "test/support/fixtures/configs/valid.yml"
  @end_of_body "\r\n0\r\n\r\n"

  # Goes through a real listener because the test adapter reports
  # `{:plug_conn, :sent}` to the conn's owner, while a real adapter sends it to
  # the request process; only the latter puts it in the loop's mailbox as
  # production does.
  test "a plugin status reaches the live SSE endpoint as a camera_status frame" do
    id = "sse_#{System.unique_integer([:positive])}"
    on_exit(fn -> Cairn.CameraStatus.delete(id) end)

    server = start_listener()
    slots = StreamLimiter.count()
    {sock, body} = open_stream(server)

    Cairn.CameraStatus.put(id, %{
      plugin_status: %{"state" => "degraded", "detail" => "cpu fallback"}
    })

    # Through the frame's blank line: TCP may split it anywhere.
    body = recv_until(sock, body, &frame?(&1, id, "cpu fallback"))

    assert body =~ "event: camera_status\n"
    assert body =~ ~s("plugin_status":{)
    assert body =~ ~s("state":"degraded")

    # A second frame proves the stream outlived the first: a refute on the
    # bytes read so far cannot see an end that has not arrived yet.
    Cairn.CameraStatus.put(id, %{plugin_status: %{"state" => "ok", "detail" => "npu back"}})
    body = recv_until(sock, body, &frame?(&1, id, "npu back"))
    refute body =~ @end_of_body

    :ok = :gen_tcp.close(sock)

    # The client is gone; the next write fails and the handler releases.
    assert eventually(fn ->
             Cairn.CameraStatus.put(id, %{status: :running})
             StreamLimiter.count() == slots
           end)
  end

  test "an open stream does not hold up the listener's shutdown" do
    server = start_listener()
    slots = StreamLimiter.count()
    {_sock, _body} = open_stream(server)
    assert StreamLimiter.count() == slots + 1

    {micros, :ok} = :timer.tc(fn -> stop_supervised(:listener) end)

    # Far under the listener's 15 s shutdown_timeout, after which the handler
    # would be killed instead.
    assert micros < 3_000_000
    assert eventually(fn -> StreamLimiter.count() == slots end)
  end

  test "a handler killed outright frees its slot" do
    server = start_listener()
    slots = StreamLimiter.count()
    {_sock, _body} = open_stream(server)
    assert StreamLimiter.count() == slots + 1

    Process.exit(handler(server), :kill)

    assert eventually(fn -> StreamLimiter.count() == slots end)
  end

  test "the stream past the cap is refused with 503" do
    server = start_listener()
    previous = Application.fetch_env(:cairn, :max_sse_connections)

    on_exit(fn ->
      case previous do
        {:ok, max} -> Application.put_env(:cairn, :max_sse_connections, max)
        :error -> Application.delete_env(:cairn, :max_sse_connections)
      end
    end)

    Application.put_env(:cairn, :max_sse_connections, StreamLimiter.count() + 1)
    {_sock, _body} = open_stream(server)

    head = recv_until(request(server), "", &(&1 =~ "\r\n\r\n"))
    assert head =~ ~r/\AHTTP\/1.1 503 /
  end

  # The supervisor's restart is logged as an error report.
  @tag :capture_log
  test "a limiter restart ends the streams whose slots it dropped" do
    server = start_listener()
    {sock, body} = open_stream(server)
    limiter = Process.whereis(StreamLimiter)

    :ok = Supervisor.stop(limiter, :shutdown)

    assert recv_until(sock, body, &String.ends_with?(&1, @end_of_body))
    # The name is registered before the successor's tables exist.
    assert eventually(fn ->
             Process.whereis(StreamLimiter) not in [nil, limiter] and
               try do
                 StreamLimiter.count() == 0
               rescue
                 ArgumentError -> false
               end
           end)
  end

  # The window between `ApiAuth` and the stream's subscribe, which no
  # broadcast will cover: entered directly with the token the plug would have
  # recorded before a rotation. Opened, the stream would block until the
  # test timed out.
  @tag timeout: 5_000
  test "a stream whose token changed before it subscribed is refused with 401" do
    conn =
      build_conn()
      |> put_private(:cairn_api_token, "rotated-away")
      |> EventStreamController.stream(%{})

    assert json_response(conn, 401) == %{"error" => "unauthorized"}
    # It subscribed before it was refused, so its process must not serve again.
    assert get_resp_header(conn, "connection") == ["close"]
  end

  describe "a config change" do
    setup :restore_fixture

    test "that rotates the token ends a stream opened with the old one", %{original: original} do
      server = start_listener()
      {sock, body} = open_stream(server)

      File.write!(@fixture, String.replace(original, "token: #{@token}", "token: rotated"))
      {:ok, _, _} = Server.reload()

      assert recv_until(sock, body, &String.ends_with?(&1, @end_of_body))
      # Not kept alive: the next request on this connection would run in the
      # process that still holds this stream's subscriptions.
      assert :gen_tcp.recv(sock, 0, 1_000) == {:error, :closed}
    end

    test "that removes the token ends the stream", %{original: original} do
      server = start_listener()
      {sock, body} = open_stream(server)

      File.write!(@fixture, String.replace(original, "integrations:\n  token: #{@token}\n", ""))
      {:ok, _, _} = Server.reload()
      assert Server.ha_token() == nil

      assert recv_until(sock, body, &String.ends_with?(&1, @end_of_body))
    end

    test "published without a broadcast ends the stream at its next frame" do
      server = start_listener()
      {sock, body} = open_stream(server)

      # What a restarted server does: a snapshot, and no `config_changed`.
      key = Server.snapshot_key(Server)
      :persistent_term.put(key, %{Server.snapshot() | ha_token: "rotated"})
      send(handler(server), {:disk_alert, %{after_rotation: true}})

      body = recv_until(sock, body, &String.ends_with?(&1, @end_of_body))
      refute body =~ "after_rotation"
    end

    test "that keeps the token leaves the stream open" do
      server = start_listener()
      {sock, body} = open_stream(server)

      {:ok, _, _} = Server.reload()
      pid = handler(server)
      # Signals from two senders arrive in no guaranteed order, so the reload's
      # broadcast alone would not prove a notification is handled before the
      # alert; one from this process is.
      send(pid, {:config_changed, %{}})
      send(pid, {:disk_alert, %{after_reload: true}})

      body = recv_until(sock, body, &(&1 =~ ~s("after_reload":true}\n\n)))
      refute body =~ @end_of_body
    end
  end

  describe "over HTTP/2" do
    setup :restore_fixture

    test "a stream opens and carries frames, with no connection header" do
      server = start_listener()
      {conn, ref, resp} = open_h2_stream(server)

      assert Mint.HTTP.protocol(conn) == :http2
      assert resp.status == 200
      assert List.keyfind(resp.headers, "connection", 0) == nil

      Phoenix.PubSub.broadcast(
        Cairn.PubSub,
        Cairn.Retention.topic(),
        {:disk_alert, %{over_h2: true}}
      )

      {_conn, _ref, resp} = h2_recv_until(conn, ref, resp, &(&1.data =~ ~s("over_h2":true}\n\n)))
      assert resp.data =~ "event: disk_alert\n"
      refute resp.done
    end

    test "rotating the token ends the stream and keeps the connection", %{original: original} do
      server = start_listener()
      slots = StreamLimiter.count()
      {conn, ref, resp} = open_h2_stream(server)

      File.write!(@fixture, String.replace(original, "token: #{@token}", "token: rotated"))
      {:ok, _, _} = Server.reload()

      {conn, _ref, resp} = h2_recv_until(conn, ref, resp, & &1.done)
      assert resp.done
      assert Mint.HTTP.open?(conn)
      assert eventually(fn -> StreamLimiter.count() == slots end)
    end

    test "an open stream does not hold up the listener's shutdown" do
      server = start_listener()
      slots = StreamLimiter.count()
      {_conn, _ref, _resp} = open_h2_stream(server)
      assert StreamLimiter.count() == slots + 1

      {micros, :ok} = :timer.tc(fn -> stop_supervised(:listener) end)

      assert micros < 3_000_000
      assert eventually(fn -> StreamLimiter.count() == slots end)
    end
  end

  # A client that reads nothing parks the handler in a socket write: small
  # buffers on both ends and frames far larger than both — more than one,
  # because the port driver queues the first whole and it is the next write
  # that waits. The flood is sent only once the handler is parked, so it all
  # queues; when the client reads again the handler finishes the write and
  # finds the backlog before its next receive.
  test "a client too slow for its backlog has the stream ended" do
    server = start_listener(thousand_island_options: [transport_options: [sndbuf: 4_096]])
    {sock, body} = open_stream(server, recbuf: 4_096)
    pid = handler(server)

    big = String.duplicate("x", 1_000_000)
    for n <- 1..3, do: send(pid, {:disk_alert, %{n: n, pad: big}})
    send(pid, :noise)
    assert eventually(fn -> parked_in_write?(pid) end)

    log =
      capture_log(fn ->
        for _ <- 1..1_100, do: send(pid, :noise)
        assert recv_until(sock, body, &String.ends_with?(&1, @end_of_body))
      end)

    assert log =~ "reads too slowly"
  end

  # The listener's exit signal is queued behind the frames; a shutdown that
  # waited for them would write all of them first.
  test "a shutdown is not held up by frames queued ahead of it" do
    server = start_listener(thousand_island_options: [transport_options: [sndbuf: 4_096]])
    {sock, body} = open_stream(server, recbuf: 4_096)
    pid = handler(server)

    big = String.duplicate("x", 1_000_000)
    for n <- 1..3, do: send(pid, {:disk_alert, %{n: n, pad: big}})
    assert eventually(fn -> parked_in_write?(pid) end)

    for n <- 1..4, do: send(pid, {:disk_alert, %{n: n + 3, pad: big}})
    send(pid, {:disk_alert, %{last: true, pad: big}})

    {:message_queue_len, queued} = Process.info(pid, :message_queue_len)
    # `stop_supervised/1` only works from the test process, which is reading
    # the socket; the supervisor's restart of the stopped listener is harmless.
    task = Task.async(fn -> Supervisor.stop(server, :shutdown) end)

    assert eventually(fn ->
             Process.info(pid, :message_queue_len) == {:message_queue_len, queued + 1}
           end)

    body = recv_until(sock, body, &String.ends_with?(&1, @end_of_body))

    refute body =~ ~s("last":true)
    assert {:ok, :ok} = Task.yield(task, 3_000)
  end

  # The loop's own `receive` matches any message, so a waiting process with a
  # non-empty queue is in someone else's selective receive: the socket write.
  defp parked_in_write?(pid) do
    info = Process.info(pid, [:status, :message_queue_len])
    info[:status] == :waiting and info[:message_queue_len] > 0
  end

  defp start_listener(opts \\ []) do
    start_supervised!(
      Supervisor.child_spec(
        {Bandit, [plug: CairnWeb.Endpoint, port: 0, ip: :loopback, startup_log: false] ++ opts},
        id: :listener
      )
    )
  end

  defp open_stream(server, sock_opts \\ []) do
    sock = request(server, sock_opts)
    {sock, recv_until(sock, "", &(&1 =~ ": connected\n\n"))}
  end

  defp request(server, sock_opts \\ []) do
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    {:ok, sock} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false] ++ sock_opts)

    :ok =
      :gen_tcp.send(
        sock,
        "GET /api/stream?access_token=#{@token} HTTP/1.1\r\nhost: localhost\r\n\r\n"
      )

    sock
  end

  defp restore_fixture(_context) do
    original = File.read!(@fixture)

    on_exit(fn ->
      File.write!(@fixture, original)
      {:ok, _, _} = Server.reload()
    end)

    %{original: original}
  end

  defp open_h2_stream(server) do
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    {:ok, conn} =
      Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http2], mode: :passive)

    {:ok, conn, ref} =
      Mint.HTTP.request(conn, "GET", "/api/stream", [{"authorization", "Bearer #{@token}"}], nil)

    resp = %{status: nil, headers: [], data: "", done: false}
    h2_recv_until(conn, ref, resp, &(&1.data =~ ": connected\n\n"))
  end

  defp h2_recv_until(conn, ref, resp, done?) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    do_h2_recv_until(conn, ref, resp, done?, deadline)
  end

  defp do_h2_recv_until(conn, ref, resp, done?, deadline) do
    if done?.(resp) do
      {conn, ref, resp}
    else
      left = max(deadline - System.monotonic_time(:millisecond), 0)

      case Mint.HTTP.recv(conn, 0, left) do
        {:ok, conn, responses} ->
          resp = Enum.reduce(responses, resp, &h2_apply(&1, &2, ref))
          do_h2_recv_until(conn, ref, resp, done?, deadline)

        {:error, _conn, reason, _responses} ->
          flunk(
            "HTTP/2 stream ended before the frame arrived: #{inspect(reason)}\n#{inspect(resp)}"
          )
      end
    end
  end

  defp h2_apply({:status, ref, status}, resp, ref), do: %{resp | status: status}

  defp h2_apply({:headers, ref, headers}, resp, ref),
    do: %{resp | headers: resp.headers ++ headers}

  defp h2_apply({:data, ref, data}, resp, ref), do: %{resp | data: resp.data <> data}
  defp h2_apply({:done, ref}, resp, ref), do: %{resp | done: true}
  defp h2_apply(_other, resp, _ref), do: resp

  defp handler(server) do
    {:ok, [pid]} = ThousandIsland.connection_pids(server)
    pid
  end

  defp frame?(body, id, detail) do
    body =~ ~r/data: \{[^\n]*"camera_id":"#{id}"[^\n]*"detail":"#{detail}"[^\n]*\}\n\n/
  end

  defp recv_until(sock, acc, done?) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    do_recv_until(sock, acc, done?, deadline)
  end

  defp do_recv_until(sock, acc, done?, deadline) do
    if done?.(acc) do
      acc
    else
      left = max(deadline - System.monotonic_time(:millisecond), 0)

      case :gen_tcp.recv(sock, 0, left) do
        {:ok, data} ->
          do_recv_until(sock, acc <> data, done?, deadline)

        {:error, reason} ->
          flunk("stream ended before the frame arrived: #{inspect(reason)}\n#{acc}")
      end
    end
  end

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() ->
        true

      tries > 0 ->
        Process.sleep(100)
        eventually(fun, tries - 1)

      true ->
        false
    end
  end
end
