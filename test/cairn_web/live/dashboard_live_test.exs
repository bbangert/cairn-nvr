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

    assert render_async_status(view, "cam_a") =~ ~s(data-status="running")
  end

  # The "events" topic carries the per-object track lifecycle as well as
  # events, and gains kinds over time (artifact lifecycle is next). The grid
  # must ignore what it does not know rather than die on it.
  test "track lifecycle broadcasts do not crash the grid", %{conn: conn} do
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

    assert render(view) =~ "camera-tile-cam_a"
  end

  defp render_async_status(view, camera_id, attempts \\ 50) do
    html = render(view)
    selector = ~s(#camera-status-#{camera_id})

    cond do
      html =~ ~s(data-status="running") ->
        element(view, selector) |> render()

      attempts == 0 ->
        element(view, selector) |> render()

      true ->
        Process.sleep(20)
        render_async_status(view, camera_id, attempts - 1)
    end
  end
end
