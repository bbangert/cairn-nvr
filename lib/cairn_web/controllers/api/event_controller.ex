defmodule CairnWeb.Api.EventController do
  @moduledoc """
  Read API over the event index for Home Assistant (Media Browser + sensors).

  Wraps `Cairn.Events`; shapes rows via `CairnWeb.Api.EventJSON` so responses
  carry `snapshot_url`/`clip_url` (token-authed) and never on-disk paths.
  """

  use CairnWeb, :controller

  alias Cairn.Events
  alias CairnWeb.Api.EventJSON

  def index(conn, params) do
    opts = [
      camera: params["camera"],
      label: params["label"],
      from: parse_time(params["from"]),
      to: parse_time(params["to"]),
      page: parse_int(params["page"], 1),
      page_size: parse_int(params["page_size"], 50)
    ]

    %{events: events, page: page, total: total} = Events.list(opts)

    json(conn, %{
      events: Enum.map(events, &EventJSON.shape_row/1),
      page: page,
      total: total
    })
  end

  def show(conn, %{"id" => id}) do
    case Events.get(id) do
      nil -> conn |> put_status(404) |> json(%{error: "not_found"})
      event -> json(conn, EventJSON.shape_row(event))
    end
  end

  def labels(conn, _params) do
    json(conn, %{labels: Events.known_labels()})
  end

  # ISO8601 → DateTime; invalid/blank values are ignored (no filter).
  defp parse_time(nil), do: nil
  defp parse_time(""), do: nil

  defp parse_time(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_int(nil, default), do: default

  defp parse_int(value, default) do
    case Integer.parse(value) do
      {n, _} when n > 0 -> n
      _ -> default
    end
  end
end
