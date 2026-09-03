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

  # Masking itself is `Cairn.StreamUrl`'s contract (see stream_url_test.exs);
  # this only proves the page actually renders through it — including the
  # colonless-userinfo shape (`rtsp://secret@host`), the exposure a smaller,
  # since-deleted credential list here once missed.
  test "a credentialed camera URL renders masked on /config", %{conn: conn} do
    original = File.read!(@fixture)
    on_exit(fn -> File.write!(@fixture, original) end)

    {:ok, view, _html} = live(conn, "/config")

    File.write!(
      @fixture,
      "data_dir: tmp/cairn_test_data\n" <>
        "cameras:\n" <>
        "  - id: cam_secret\n" <>
        "    rtsp_url: rtsp://admin:s3cret@127.0.0.1:8554/a\n" <>
        "  - id: cam_colonless\n" <>
        "    rtsp_url: rtsp://s3cretonly@127.0.0.1:8554/b\n"
    )

    html = render_click(view, "reload", %{})

    assert html =~ "rtsp://admin:•••••@127.0.0.1:8554/a"
    assert html =~ "rtsp://•••••@127.0.0.1:8554/b"
    refute html =~ "s3cret@"
    refute html =~ "s3cretonly"

    File.write!(@fixture, original)
    render_click(view, "reload", %{})
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
