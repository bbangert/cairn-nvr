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
end
