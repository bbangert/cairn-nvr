defmodule CairnWeb.HLSController do
  @moduledoc """
  Minimal live-HLS fallback straight from the ring buffer — a live playlist
  with `EXT-X-MAP` init, no library, no disk. Segment URIs are the ring's
  monotonic fragment seqs, so `EXT-X-MEDIA-SEQUENCE` is correct across
  ffmpeg session restarts.
  """

  use CairnWeb, :controller

  alias Cairn.RingBuffer

  @playlist_fragments 6

  def playlist(conn, %{"camera" => camera_id}) do
    case ring_data(camera_id, @playlist_fragments) do
      {:ok, %{fragments: [_ | _] = frags}} ->
        target =
          frags
          |> Enum.map(&ceil(&1.duration_ms / 1000))
          |> Enum.max()
          |> max(1)

        lines =
          [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:#{target}",
            "#EXT-X-MEDIA-SEQUENCE:#{hd(frags).seq}",
            ~s(#EXT-X-MAP:URI="init.mp4")
          ] ++
            Enum.flat_map(frags, fn frag ->
              ["#EXTINF:#{Float.round(frag.duration_ms / 1000, 3)},", "#{frag.seq}.m4s"]
            end)

        conn
        |> put_resp_content_type("application/vnd.apple.mpegurl")
        |> put_no_store()
        |> send_resp(200, Enum.join(lines, "\n") <> "\n")

      _ ->
        not_found(conn)
    end
  end

  def init_segment(conn, %{"camera" => camera_id}) do
    case ring_data(camera_id, 0) do
      {:ok, %{init: init}} when is_binary(init) ->
        conn
        |> put_resp_content_type("video/mp4")
        |> put_no_store()
        |> send_resp(200, init)

      _ ->
        not_found(conn)
    end
  end

  def segment(conn, %{"camera" => camera_id, "segment" => name}) do
    with {seq, ".m4s"} <- Integer.parse(name),
         {:ok, %{fragments: frags}} <- ring_data(camera_id, 100),
         %Cairn.Fragment{} = frag <- Enum.find(frags, &(&1.seq == seq)) do
      conn
      |> put_resp_content_type("video/iso.segment")
      |> put_no_store()
      |> send_resp(200, frag.data)
    else
      _ -> not_found(conn)
    end
  end

  # `fetch_recent_safe/2` and not `fetch_recent/2`: the whereis can hand back a
  # ring the registry has not reaped yet, and a via-tuple call on a dead pid
  # exits — every caller here matches on values, so that would 500 instead of
  # 404.
  defp ring_data(camera_id, count) do
    case Cairn.Registry.whereis(camera_id, :ring_buffer) do
      nil -> {:error, :offline}
      _pid -> RingBuffer.fetch_recent_safe(camera_id, count)
    end
  end

  defp put_no_store(conn), do: put_resp_header(conn, "cache-control", "no-store")

  defp not_found(conn), do: send_resp(conn, 404, "not found")
end
