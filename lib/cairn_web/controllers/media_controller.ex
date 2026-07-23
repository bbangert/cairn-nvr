defmodule CairnWeb.MediaController do
  @moduledoc """
  Serves recorded media from disk, resolved through the event index (never
  from user-supplied paths).

  `GET /media/events/:id` supports HTTP Range requests (single range) so
  `<video>` seeking works; `GET /media/snapshots/:id` serves the event's
  snapshot jpg.
  """

  use CairnWeb, :controller

  alias Cairn.Events

  def event_clip(conn, %{"id" => id}) do
    with %{path: path} when is_binary(path) <- Events.get(id) || :not_found,
         {:ok, %File.Stat{size: size}} <- File.stat(path) do
      conn =
        conn
        |> put_resp_content_type("video/mp4")
        |> put_resp_header("accept-ranges", "bytes")

      case get_req_header(conn, "range") do
        ["bytes=" <> range] -> send_range(conn, path, size, range)
        _ -> send_file(conn, 200, path)
      end
    else
      _ -> send_resp(conn, 404, "not found")
    end
  end

  def snapshot(conn, %{"id" => id}) do
    with %{snapshot_path: path} when is_binary(path) <- Events.get(id) || :not_found,
         {:ok, _stat} <- File.stat(path) do
      conn
      |> put_resp_content_type("image/jpeg")
      |> put_resp_header("cache-control", "private, max-age=3600")
      |> send_file(200, path)
    else
      _ -> send_resp(conn, 404, "not found")
    end
  end

  defp send_range(conn, path, size, range) do
    case parse_range(range, size) do
      {from, to} ->
        conn
        |> put_resp_header("content-range", "bytes #{from}-#{to}/#{size}")
        |> send_file(206, path, from, to - from + 1)

      :error ->
        conn
        |> put_resp_header("content-range", "bytes */#{size}")
        |> send_resp(416, "")
    end
  end

  # single-range forms: "0-499", "500-", "-500"
  defp parse_range(range, size) do
    case String.split(range, "-", parts: 2) do
      ["", suffix] -> suffix_range(suffix, size)
      [from, ""] -> open_range(from, size)
      [from, to] -> bounded_range(from, to, size)
      _ -> :error
    end
  end

  defp suffix_range(suffix, size) do
    case Integer.parse(suffix) do
      {n, ""} when n > 0 -> {max(size - n, 0), size - 1}
      _ -> :error
    end
  end

  defp open_range(from, size) do
    case Integer.parse(from) do
      {from, ""} when from < size -> {from, size - 1}
      _ -> :error
    end
  end

  defp bounded_range(from, to, size) do
    with {from, ""} <- Integer.parse(from),
         {to, ""} <- Integer.parse(to),
         true <- from <= to and from < size do
      {from, min(to, size - 1)}
    else
      _ -> :error
    end
  end
end
