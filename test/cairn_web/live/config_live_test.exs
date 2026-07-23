defmodule CairnWeb.ConfigLiveTest do
  use CairnWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @fixture "test/support/fixtures/configs/valid.yml"

  test "renders globals and cameras with masked credentials", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/config")

    assert html =~ "config-globals"
    assert html =~ "config-camera-cam_a"
    assert html =~ "config-camera-cam_b"
  end

  test "mask_url hides rtsp credentials" do
    assert CairnWeb.ConfigLive.mask_url("rtsp://admin:s3cret@10.0.0.5:554/s1") ==
             "rtsp://admin:*****@10.0.0.5:554/s1"

    assert CairnWeb.ConfigLive.mask_url("rtsp://10.0.0.5:554/s1") == "rtsp://10.0.0.5:554/s1"
  end

  test "reload with valid config shows result", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/config")

    html = render_click(view, "reload", %{})
    assert html =~ "Reloaded."
  end

  test "reload with invalid YAML keeps old config and shows errors", %{conn: conn} do
    original = File.read!(@fixture)
    on_exit(fn -> File.write!(@fixture, original) end)

    {:ok, view, _html} = live(conn, "/config")

    File.write!(@fixture, "cameras: [{id: broken}]\n")
    html = render_click(view, "reload", %{})

    assert html =~ "previous config still active"
    assert html =~ "rtsp_url is required"
    # old config still rendered
    assert html =~ "config-camera-cam_a"

    # restore and reload back to a clean state for other tests
    File.write!(@fixture, original)
    render_click(view, "reload", %{})
  end
end
