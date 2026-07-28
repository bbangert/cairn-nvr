defmodule CairnWeb.HLSControllerTest do
  # async: false is load-bearing: the stale-entry test suspends
  # `Cairn.Registry`'s partition, which the whole application shares.
  use CairnWeb.ConnCase, async: false

  import Cairn.RegistryHelpers, only: [stale_entry: 2]

  alias Cairn.Fragment
  alias Cairn.RingBuffer

  @camera "cam_a"
  @timescale 90_000

  setup do
    start_supervised!({RingBuffer, camera_id: @camera, pre_window_seconds: 60})
    RingBuffer.put_init(@camera, <<"INIT">>, "avc1.64001f", @timescale, Cairn.ULID.generate())

    for second <- 0..3 do
      RingBuffer.put_fragment(@camera, %Fragment{
        camera_id: @camera,
        seq: 0,
        pts: second * @timescale,
        duration_ms: 2_000,
        timescale: @timescale,
        data: <<second::32>>
      })
    end

    :ok
  end

  test "playlist lists recent segments with EXT-X-MAP init", %{conn: conn} do
    conn = get(conn, "/hls/#{@camera}/index.m3u8")

    assert response(conn, 200)
    assert response_content_type(conn, :"vnd.apple.mpegurl") =~ "application"
    body = conn.resp_body

    assert body =~ "#EXTM3U"
    assert body =~ "#EXT-X-MEDIA-SEQUENCE:0"
    assert body =~ ~s(#EXT-X-MAP:URI="init.mp4")
    assert body =~ "#EXTINF:2.0,"
    assert body =~ "3.m4s"
    refute body =~ "#EXT-X-ENDLIST"
  end

  test "init.mp4 serves the init segment", %{conn: conn} do
    conn = get(conn, "/hls/#{@camera}/init.mp4")
    assert response(conn, 200) == "INIT"
  end

  test "segments are served by ring seq", %{conn: conn} do
    conn = get(conn, "/hls/#{@camera}/2.m4s")
    assert response(conn, 200) == <<2::32>>
  end

  test "evicted or unknown segment is 404", %{conn: conn} do
    assert conn |> get("/hls/#{@camera}/99.m4s") |> response(404)
    assert conn |> get("/hls/#{@camera}/nonsense.m4s") |> response(404)
  end

  test "offline camera is 404 everywhere", %{conn: conn} do
    assert conn |> get("/hls/offline_cam/index.m3u8") |> response(404)
    assert conn |> get("/hls/offline_cam/init.mp4") |> response(404)
    assert conn |> get("/hls/offline_cam/0.m4s") |> response(404)
  end

  # The registry lists the ring for a moment after it dies, so the whereis
  # guard passes and the via-tuple `fetch_recent` exits `:noproc`. That must
  # still be a 404, not a 500.
  test "a stale ring registry entry is 404, not a 500", %{conn: conn} do
    ring = stale_entry("stale_cam", :ring_buffer)
    refute Process.alive?(ring)

    assert conn |> get("/hls/stale_cam/index.m3u8") |> response(404)
    assert conn |> get("/hls/stale_cam/init.mp4") |> response(404)
    assert conn |> get("/hls/stale_cam/0.m4s") |> response(404)
  end
end
