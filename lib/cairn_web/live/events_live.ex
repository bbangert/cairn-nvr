defmodule CairnWeb.EventsLive do
  @moduledoc """
  Event browser (functional scaffold — visual design from the Claude
  Design handoff).

  Data contract: filters form (`phx-change="filter"`, fields
  camera/label/from/to), streams-based list (`#events-list`,
  `phx-update="stream"`), pagination (`phx-click="page"`).
  """

  use CairnWeb, :live_view

  alias Cairn.Events

  @page_size 25

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket, page_title: "Events", cameras: camera_ids(), labels: Events.known_labels())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = %{
      camera: params["camera"] || "",
      label: params["label"] || "",
      from: params["from"] || "",
      to: params["to"] || ""
    }

    page =
      case Integer.parse(params["page"] || "1") do
        {n, ""} when n >= 1 -> n
        _ -> 1
      end

    result =
      Events.list(
        camera: filters.camera,
        label: filters.label,
        from: parse_date(filters.from, ~T[00:00:00]),
        to: parse_date(filters.to, ~T[23:59:59]),
        page: page,
        page_size: @page_size
      )

    {:noreply,
     socket
     |> assign(
       filters: filters,
       page: result.page,
       total: result.total,
       has_next: result.page * @page_size < result.total
     )
     |> stream(:events, result.events, reset: true)}
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply, push_patch(socket, to: ~p"/events?#{filter_query(params, 1)}")}
  end

  def handle_event("page", %{"page" => page}, socket) do
    {:noreply, push_patch(socket, to: ~p"/events?#{filter_query(socket.assigns.filters, page)}")}
  end

  defp filter_query(params, page) do
    %{
      "camera" => params["camera"] || params[:camera] || "",
      "label" => params["label"] || params[:label] || "",
      "from" => params["from"] || params[:from] || "",
      "to" => params["to"] || params[:to] || "",
      "page" => page
    }
    |> Enum.reject(fn {_k, v} -> v in ["", nil] end)
    |> Map.new()
  end

  defp parse_date("", _time), do: nil

  defp parse_date(date_str, time) do
    with {:ok, date} <- Date.from_iso8601(date_str),
         {:ok, naive} <- NaiveDateTime.new(date, time) do
      DateTime.from_naive!(naive, "Etc/UTC")
    else
      _ -> nil
    end
  end

  defp camera_ids, do: Enum.map(Cairn.Config.Server.get().cameras, & &1.id)

  defp duration(%{started_at: s, ended_at: %DateTime{} = e}), do: "#{DateTime.diff(e, s)}s"
  defp duration(_), do: "—"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <h1>Events</h1>

      <form id="event-filters" phx-change="filter">
        <select name="camera">
          <option value="">All cameras</option>
          <option :for={c <- @cameras} value={c} selected={@filters.camera == c}>{c}</option>
        </select>
        <select name="label">
          <option value="">All labels</option>
          <option :for={l <- @labels} value={l} selected={@filters.label == l}>{l}</option>
        </select>
        <input type="date" name="from" value={@filters.from} />
        <input type="date" name="to" value={@filters.to} />
      </form>

      <p :if={@total == 0} id="events-empty">No events match.</p>

      <ul id="events-list" phx-update="stream">
        <li :for={{dom_id, event} <- @streams.events} id={dom_id}>
          <.link navigate={~p"/events/#{event.id}"}>
            <img
              :if={event.snapshot_path}
              src={~p"/media/snapshots/#{event.id}"}
              alt=""
              width="160"
              loading="lazy"
            />
            <span class="camera">{event.camera_id}</span>
            <time datetime={DateTime.to_iso8601(event.started_at)}>
              {Calendar.strftime(event.started_at, "%Y-%m-%d %H:%M:%S")}
            </time>
            <span class="duration">{duration(event)}</span>
            <span
              :for={{label, score} <- Map.get(event.labels, "max_scores", %{})}
              class="label-chip"
            >
              {label} {trunc(score * 100)}%
            </span>
            <span :if={event.status == :partial} class="badge-partial">partial</span>
          </.link>
        </li>
      </ul>

      <nav id="events-pagination">
        <button :if={@page > 1} phx-click="page" phx-value-page={@page - 1}>Previous</button>
        <span>page {@page} — {@total} events</span>
        <button :if={@has_next} phx-click="page" phx-value-page={@page + 1}>
          Next
        </button>
      </nav>
    </Layouts.app>
    """
  end
end
