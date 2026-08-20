defmodule CairnWeb.DashboardLiveTest do
  use CairnWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "renders a tile per configured camera", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")

    assert html =~ "camera-tile-cam_a"
    assert html =~ "camera-tile-cam_b"
    assert html =~ ~s(data-camera-id="cam_a")
    assert html =~ "/hls/cam_a/index.m3u8"
  end

  test "camera status updates live", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    # reset the globally-shared status table after the test
    on_exit(fn -> Cairn.CameraStatus.merge("cam_a", %{status: :unknown}) end)
    Cairn.CameraStatus.set("cam_a", :running)

    # the set is a cast whose broadcast happens inside the callback, so once
    # the server's mailbox has flushed the frame is already in the view's —
    # ahead of the render call that follows. No polling needed.
    _ = :sys.get_state(Cairn.CameraStatus)

    assert render(view) =~ ~s(data-status="running")
  end

  # The "events" topic carries the per-object track and artifact lifecycles as
  # well as events, and gains kinds over time. The grid must ignore what it
  # does not know rather than die on it.
  test "track and artifact lifecycle broadcasts do not crash the grid", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    track = %Cairn.Track{
      object_id: Cairn.ULID.generate(),
      camera_id: "cam_a",
      label: "person",
      score: 0.9,
      best_score: 0.9,
      bbox: [0.1, 0.1, 0.2, 0.4],
      source: :host,
      started_at: DateTime.utc_now(),
      last_seen_at: DateTime.utc_now()
    }

    Cairn.Track.broadcast(:track_started, track)
    Cairn.Track.broadcast(:track_updated, track)
    Cairn.Track.broadcast(:track_ended, %{track | end_reason: :unseen})

    artifact = %Cairn.EventArtifact{event_id: Cairn.ULID.generate(), camera_id: "cam_a"}

    Cairn.EventArtifact.broadcast(:event_clip_ready, %{
      artifact
      | path: "/tmp/clip.mp4",
        bytes: 1_024
    })

    Cairn.EventArtifact.broadcast(:event_clip_failed, %{artifact | reason: :not_found})

    Cairn.EventArtifact.broadcast(:event_snapshot_ready, %{
      artifact
      | path: "/tmp/snap.jpg",
        bytes: 512
    })

    Cairn.EventArtifact.broadcast(:event_snapshot_failed, %{artifact | reason: :no_output})

    # the track and artifact kinds are ones the grid may legitimately grow a
    # clause for; the forward-compat claim is about a kind it has never heard of
    Phoenix.PubSub.local_broadcast(
      Cairn.PubSub,
      Cairn.Event.topic(),
      {:totally_unknown_kind, %{}}
    )

    html = render(view)
    assert html =~ "camera-tile-cam_a"
    # tolerated, not acted on: none of these announces an event *opening*, so
    # the REC marker must stay off — the tile alone renders either way
    refute html =~ "camera-live-event-cam_a"
  end

  describe "live transport" do
    test "WebRTC is the default, MSE is one click away", %{conn: conn} do
      {:ok, view, html} = live(conn, "/")

      assert html =~ ~s(data-transport="webrtc")
      assert html =~ ~s(id="camera-video-cam_a-webrtc")
      assert html =~ ~s(phx-hook="WebrtcPlayer")

      html =
        view
        |> element(~s(#camera-transport-cam_a button[phx-value-transport="mse"]))
        |> render_click()

      assert html =~ ~s(data-transport="mse")
      assert html =~ ~s(id="camera-video-cam_a-mse")
    end

    # The fallback is the player's error path, not a feature check: a browser
    # that speaks WebRTC can still sit behind a network that drops the media.
    test "a WebRTC player that fails falls the camera back to MSE", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      html = render_hook(view, "transport_failed", %{"camera_id" => "cam_a"})

      # the toggle must show the transport actually in use, and the <video>'s
      # id is what makes LiveView swap the hook rather than patch it
      assert html =~ ~s(data-transport="mse")
      assert html =~ ~s(id="camera-video-cam_a-mse")
      assert html =~ ~s(phx-hook="MsePlayer")

      # one camera's failure is not the fleet's
      assert html =~ ~s(id="camera-video-cam_b-webrtc")
    end

    # The fallback writes the same assign the buttons do, so it must not be a
    # one-way door: an operator who fixes the network gets WebRTC back with
    # one click, and the fresh hook re-arms the overlay gate from scratch.
    test "a camera that fell back to MSE can be toggled to WebRTC again", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert render_hook(view, "transport_failed", %{"camera_id" => "cam_a"}) =~
               ~s(id="camera-video-cam_a-mse")

      html =
        view
        |> element(~s(#camera-transport-cam_a button[phx-value-transport="webrtc"]))
        |> render_click()

      assert html =~ ~s(data-transport="webrtc")
      assert html =~ ~s(id="camera-video-cam_a-webrtc")
      assert html =~ ~s(phx-hook="WebrtcPlayer")

      # the new hook has not reported yet, so the overlay stays down until it
      # does — the gate is per player instance, not remembered per camera
      refute html =~ "camera-overlay-cam_a"

      assert render_hook(view, "webrtc_active", %{"camera_id" => "cam_a"}) =~
               "camera-overlay-cam_a"
    end

    test "one camera's fallback leaves another's overlay alone", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      render_hook(view, "webrtc_active", %{"camera_id" => "cam_a"})

      Cairn.LiveDetections.broadcast("cam_a", [
        %{label: "person", score: 0.9, bbox: [0.1, 0.1, 0.2, 0.2]}
      ])

      html = render_hook(view, "transport_failed", %{"camera_id" => "cam_b"})

      assert html =~ "camera-overlay-cam_a"
      assert html =~ "person · 0.90"
      assert html =~ ~s(id="camera-video-cam_b-mse")
    end

    test "a report for a camera this page does not show is ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      html = render_hook(view, "transport_failed", %{"camera_id" => "not_a_camera"})
      assert html =~ ~s(data-transport="webrtc")

      html = render_hook(view, "webrtc_active", %{"camera_id" => "not_a_camera"})
      refute html =~ "camera-overlay-"
    end
  end

  describe "live detection overlay" do
    defp detection(label, score, bbox), do: %{label: label, score: score, bbox: bbox}

    defp activate(view, camera_id) do
      render_hook(view, "webrtc_active", %{"camera_id" => camera_id})
      view
    end

    defp publish(view, camera_id, detections) do
      Cairn.LiveDetections.broadcast(camera_id, detections)
      # local_broadcast delivers from this process, so the frame is in the
      # view's mailbox ahead of the render call's own message. No polling.
      render(view)
    end

    test "boxes draw with percent geometry from the normalized box", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      html =
        view
        |> activate("cam_a")
        |> publish("cam_a", [detection("person", 0.9, [0.1, 0.2, 0.3, 0.4])])

      assert html =~ "camera-overlay-cam_a"
      assert html =~ "bbox-corners"
      assert html =~ "left: 10.0%"
      assert html =~ "top: 20.0%"
      assert html =~ "width: 30.0%"
      assert html =~ "height: 40.0%"
      assert html =~ "person · 0.90"
    end

    test "a box flush against the frame edge is clamped inside it", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      html =
        view
        |> activate("cam_a")
        |> publish("cam_a", [detection("car", 0.5, [0.0, 0.0, 1.0, 1.0])])

      # lawik's 0.5–99.5: a bracket drawn on the boundary is half outside the
      # video, and the width has to give back what the offset took.
      assert html =~ "left: 0.5%"
      assert html =~ "top: 0.5%"
      assert html =~ "width: 99.0%"
      assert html =~ "height: 99.0%"
    end

    # The same helper the playback overlay colours by, so one label looks the
    # same live and over the recorded clip.
    test "colour is keyed by label, not by position", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      html =
        view
        |> activate("cam_a")
        |> publish("cam_a", [
          detection("person", 0.9, [0.1, 0.1, 0.1, 0.1]),
          detection("car", 0.9, [0.5, 0.5, 0.1, 0.1])
        ])

      assert html =~ "--c: #{CairnWeb.EventsLive.track_color("person", 0)}"
      assert html =~ "--c: #{CairnWeb.EventsLive.track_color("car", 0)}"
    end

    test "each broadcast replaces the camera's whole list", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      view = activate(view, "cam_a")

      html = publish(view, "cam_a", [detection("person", 0.9, [0.1, 0.1, 0.2, 0.2])])
      assert html =~ "person · 0.90"

      html = publish(view, "cam_a", [detection("car", 0.8, [0.3, 0.3, 0.2, 0.2])])
      assert html =~ "car · 0.80"
      refute html =~ "person · 0.90"
    end

    test "an empty list takes the boxes down without a staleness timer", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      view = activate(view, "cam_a")

      assert publish(view, "cam_a", [detection("person", 0.9, [0.1, 0.1, 0.2, 0.2])]) =~
               "bbox-corners"

      html = publish(view, "cam_a", [])
      refute html =~ "bbox-corners"
      assert html =~ "no detections"
    end

    test "nothing draws until the player reports a frame", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # detections arrive first — the assign is held, the overlay is not drawn
      html = publish(view, "cam_a", [detection("person", 0.9, [0.1, 0.1, 0.2, 0.2])])
      refute html =~ "camera-overlay-cam_a"
      refute html =~ "bbox-corners"

      html = render_hook(view, "webrtc_active", %{"camera_id" => "cam_a"})
      assert html =~ "camera-overlay-cam_a"
      assert html =~ "bbox-corners"
    end

    test "a player that loses its picture takes its boxes with it", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      view = activate(view, "cam_a")

      assert publish(view, "cam_a", [detection("person", 0.9, [0.1, 0.1, 0.2, 0.2])]) =~
               "bbox-corners"

      html = render_hook(view, "webrtc_inactive", %{"camera_id" => "cam_a"})
      refute html =~ "camera-overlay-cam_a"

      # and it does not come back stale when the player does: the boxes were
      # dropped with the frame they described
      html = render_hook(view, "webrtc_active", %{"camera_id" => "cam_a"})
      assert html =~ "camera-overlay-cam_a"
      refute html =~ "bbox-corners"
      assert html =~ "no detections"
    end

    # v1 attaches no frame time to a box, so it can only be drawn over a
    # transport at the live edge. MSE sits ~3s back by design and the boxes
    # would lead the picture.
    test "boxes do not draw over MSE, whatever the player has reported", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      view = activate(view, "cam_a")

      assert publish(view, "cam_a", [detection("person", 0.9, [0.1, 0.1, 0.2, 0.2])]) =~
               "bbox-corners"

      # the player is still active and the detections are still assigned —
      # the transport alone takes the overlay and its summary down
      html = render_hook(view, "transport_failed", %{"camera_id" => "cam_a"})
      refute html =~ "camera-overlay-cam_a"
      refute html =~ "bbox-corners"
      refute html =~ "camera-detections-cam_a"

      # …and the gate composes with the player one rather than replacing it:
      # toggling back is a real switch, so the stale activity is cleared and
      # the overlay waits for the NEW player's report and a fresh frame
      html =
        view
        |> element(~s(#camera-transport-cam_a button[phx-value-transport="webrtc"]))
        |> render_click()

      refute html =~ "camera-overlay-cam_a"

      view = activate(view, "cam_a")
      html = publish(view, "cam_a", [detection("person", 0.9, [0.1, 0.1, 0.2, 0.2])])
      assert html =~ "camera-overlay-cam_a"
      assert html =~ "person · 0.90"
    end

    test "a manual switch to MSE takes the overlay down too", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      view = activate(view, "cam_a")
      publish(view, "cam_a", [detection("car", 0.8, [0.2, 0.2, 0.2, 0.2])])

      html =
        view
        |> element(~s(#camera-transport-cam_a button[phx-value-transport="mse"]))
        |> render_click()

      refute html =~ "camera-overlay-cam_a"
      # the other camera is untouched — the gate is per camera, not per page
      assert html =~ "camera-video-cam_b-webrtc"
    end

    # A REAL switch starts a new player the old activity report must not vouch
    # for — the fresh <video> would draw the old boxes before its first frame.
    # Re-clicking the selected transport is not a switch and must not blank a
    # healthy overlay.
    test "a transport switch clears activity; a re-click does not", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      view = activate(view, "cam_a")
      publish(view, "cam_a", [detection("person", 0.9, [0.1, 0.1, 0.2, 0.2])])

      # re-click the already-selected transport: overlay untouched
      html =
        view
        |> element(~s(#camera-transport-cam_a button[phx-value-transport="webrtc"]))
        |> render_click()

      assert html =~ "camera-overlay-cam_a"

      # a real switch away and back: the stale activity is gone, so nothing
      # draws until the NEW player reports — then boxes need a fresh publish
      view
      |> element(~s(#camera-transport-cam_a button[phx-value-transport="mse"]))
      |> render_click()

      html =
        view
        |> element(~s(#camera-transport-cam_a button[phx-value-transport="webrtc"]))
        |> render_click()

      refute html =~ "camera-overlay-cam_a"
      html = view |> activate("cam_a") |> render()
      refute html =~ "person"
    end

    test "one camera's detections never land on another's tile", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      view = view |> activate("cam_a") |> activate("cam_b")

      publish(view, "cam_a", [detection("person", 0.9, [0.1, 0.1, 0.2, 0.2])])
      html = publish(view, "cam_b", [])

      assert view |> element("#camera-detections-cam_a") |> render() =~ "person"
      assert view |> element("#camera-detections-cam_b") |> render() =~ "no detections"
      assert html =~ "person · 0.90"
    end

    test "the summary counts labels, busiest first", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      view = activate(view, "cam_a")

      publish(view, "cam_a", [
        detection("person", 0.9, [0.1, 0.1, 0.1, 0.1]),
        detection("car", 0.8, [0.3, 0.3, 0.1, 0.1]),
        detection("person", 0.7, [0.5, 0.5, 0.1, 0.1])
      ])

      assert view |> element("#camera-detections-cam_a") |> render() =~ "2 person, car"
    end
  end

  describe "detector health" do
    setup do
      on_exit(fn -> Cairn.CameraStatus.set_plugin_status("cam_a", nil) end)
      :ok
    end

    defp show(conn, plugin_status) do
      Cairn.CameraStatus.set_plugin_status("cam_a", plugin_status)
      _flushed = :sys.get_state(Cairn.CameraStatus)
      {:ok, _view, html} = live(conn, "/")
      html
    end

    test "a camera nothing has reported for shows no chip", %{conn: conn} do
      refute show(conn, nil) =~ "camera-detection-cam_a"
    end

    test "each health verdict is drawn differently", %{conn: conn} do
      rendered =
        Map.new(~w(healthy saturated wedged idle unknown), fn health ->
          {health, show(conn, %{"state" => "x", "detail" => "d", "health" => health})}
        end)

      assert rendered["healthy"] =~ ~s(data-health="healthy")
      assert rendered["healthy"] =~ "Detecting"
      assert rendered["saturated"] =~ "Saturated"
      assert rendered["wedged"] =~ "Accelerator wedged"
      assert rendered["idle"] =~ "Idle"
      assert rendered["unknown"] =~ "Unknown"

      # a wedge is an alert and saturation is load: they must not share a colour
      assert rendered["wedged"] =~ "var(--hs-danger)"
      assert rendered["saturated"] =~ "var(--hs-warning)"
      assert rendered["healthy"] =~ "var(--hs-success)"
    end

    test "the detail is what the operator is given to act on", %{conn: conn} do
      html =
        show(conn, %{
          "state" => "error",
          "health" => "unknown",
          "detail" => "the canary refused m.onnx: SIGSEGV — the model was NOT loaded in this VM"
        })

      assert html =~ "the canary refused m.onnx: SIGSEGV"
    end

    # The case that motivated the precedence: nothing is inferring, so `health`
    # is honestly `idle` — and an operator reading "Idle" would never learn the
    # canary had refused the model.
    test "a failed engine outranks its health verdict", %{conn: conn} do
      html =
        show(conn, %{
          "state" => "error",
          "health" => "idle",
          "detail" => "the canary refused m.onnx: SIGSEGV — the model was NOT loaded in this VM"
        })

      assert html =~ "Detection failed"
      assert html =~ "var(--hs-danger)"
      assert html =~ "the canary refused m.onnx: SIGSEGV"
      refute html =~ "Idle"
    end

    # The sibling of the failed-engine case: health is honestly `:unknown`
    # while the model loads, and "Unknown" tells an operator nothing.
    test "a loading engine outranks its health verdict too", %{conn: conn} do
      html =
        show(conn, %{
          "state" => "starting",
          "health" => "unknown",
          "detail" => "the engine is still opening its model"
        })

      # The label is the discriminator — the detail rides both branches, and
      # health would have labelled this "Unknown".
      assert html =~ "Starting"
      assert html =~ "still opening its model"
    end

    # `state` is a free string in the plugin contract, which forbids branching
    # on it: a plugin's status is shown, never interpreted.
    test "a plugin's own status still renders, uncoloured", %{conn: conn} do
      Cairn.CameraStatus.set_plugin_status("cam_a", %{
        "state" => "degraded",
        "detail" => "cpu fallback"
      })

      _flushed = :sys.get_state(Cairn.CameraStatus)
      {:ok, view, _html} = live(conn, "/")

      # The chip, not the page: `Cairn.Native.Status` writes health-bearing
      # statuses for every camera it serves, so a concurrent test exercising
      # the host can legitimately put `data-health` on ANOTHER camera's chip
      # mid-render — a page-wide refute reads that as this test's failure.
      chip = view |> element("#camera-detection-cam_a") |> render()
      assert chip =~ "degraded"
      refute chip =~ ~s(data-health=)
    end
  end
end
