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

    Cairn.CameraStatus.set("cam_a", :running)

    assert render_async_status(view, "cam_a") =~ ~s(data-status="running")
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
