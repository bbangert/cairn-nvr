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
             "rtsp://admin:•••••@10.0.0.5:554/s1"

    assert CairnWeb.ConfigLive.mask_url("rtsp://10.0.0.5:554/s1") == "rtsp://10.0.0.5:554/s1"
  end

  test "mask_url hides credential query params (http-flv style)" do
    assert CairnWeb.ConfigLive.mask_url(
             "http://10.0.0.5/flv?port=1935&stream=ch0&user=admin&password=hunter2"
           ) == "http://10.0.0.5/flv?port=1935&stream=ch0&user=•••••&password=•••••"

    assert CairnWeb.ConfigLive.mask_url("http://10.0.0.5/flv?Token=abc&x=1") ==
             "http://10.0.0.5/flv?Token=•••••&x=1"
  end

  test "reload with valid config shows result", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/config")

    html = render_click(view, "reload", %{})
    assert html =~ "Config reloaded — changes are live"
  end

  test "reload with invalid YAML keeps old config and shows errors", %{conn: conn} do
    original = File.read!(@fixture)
    on_exit(fn -> File.write!(@fixture, original) end)

    {:ok, view, _html} = live(conn, "/config")

    File.write!(@fixture, "cameras: [{id: broken}]\n")
    html = render_click(view, "reload", %{})

    assert html =~ "previous config is still active"
    assert html =~ "rtsp_url is required"
    # old config still rendered
    assert html =~ "config-camera-cam_a"

    # restore and reload back to a clean state for other tests
    File.write!(@fixture, original)
    render_click(view, "reload", %{})
  end

  # This LiveView reads the application's own `Config.Server` — there is no
  # injection seam — so the empty fleet has to be reached the way an operator
  # would: a valid reload that removes every camera, then a broken one the
  # server refuses, which keeps that empty config while reporting errors.
  test "an errored load with no cameras left says so", %{conn: conn} do
    original = File.read!(@fixture)

    on_exit(fn ->
      File.write!(@fixture, original)
      Cairn.Config.Server.reload()
    end)

    {:ok, view, _html} = live(conn, "/config")

    File.write!(@fixture, "data_dir: tmp/cairn_test_data\ncameras: []\n")
    html = render_click(view, "reload", %{})
    refute html =~ "config-no-cameras"

    File.write!(@fixture, "cameras: [{id: broken}]\n")
    html = render_click(view, "reload", %{})

    assert html =~ "config-no-cameras"
    assert html =~ "No cameras are running."

    File.write!(@fixture, original)
    render_click(view, "reload", %{})
  end
end
