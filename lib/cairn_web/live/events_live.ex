defmodule CairnWeb.EventsLive do
  @moduledoc """
  Event browser, styled per the Claude Design handoff. Functional
  contracts preserved: `phx-change="filter"` form (camera/label/from/to),
  streams container `#events-list` with `phx-update="stream"`,
  `phx-click="page"` pagination.
  """

  use CairnWeb, :live_view

  alias Cairn.{Event, Events}

  @page_size 25

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Event.subscribe()

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
       showing_from: (result.page - 1) * @page_size + 1,
       showing_to: (result.page - 1) * @page_size + length(result.events),
       has_next: result.page * @page_size < result.total,
       visible: MapSet.new(result.events, & &1.id)
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

  def handle_event("clear-filters", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/events")}
  end

  # Live updates off the "events" topic. Rows are re-fetched from the DB so the
  # stream always holds the same shape handle_params produces (the broadcast
  # struct's labels is a list, not the "max_scores" map the row renders).
  @impl true
  def handle_info({:event_started, %Event{} = ev}, socket) do
    {:noreply, live_insert(socket, ev)}
  end

  def handle_info({:event_updated, %Event{} = ev}, socket) do
    {:noreply, live_update(socket, ev)}
  end

  def handle_info({:event_ended, %Event{} = ev}, socket) do
    socket = live_update(socket, ev)
    # the snapshot is written async just after finalize with no broadcast of
    # its own; pull the row once more shortly so the thumbnail fills in
    if MapSet.member?(socket.assigns.visible, ev.id) do
      Process.send_after(self(), {:refresh_row, ev.id}, 1_500)
    end

    {:noreply, socket}
  end

  def handle_info({:refresh_row, id}, socket) do
    {:noreply, live_update(socket, %Event{id: id, camera_id: "", started_at: DateTime.utc_now()})}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # New event: prepend only on the latest view (page 1, no conflicting filter),
  # so browsing an older page or a filtered slice stays put.
  defp live_insert(socket, ev) do
    if socket.assigns.page == 1 and not MapSet.member?(socket.assigns.visible, ev.id) and
         matches?(socket.assigns.filters, ev) do
      case Events.get(ev.id) do
        nil ->
          socket

        row ->
          socket
          |> stream_insert(:events, row, at: 0)
          |> update(:visible, &MapSet.put(&1, ev.id))
          |> update(:total, &(&1 + 1))
          |> update(:showing_to, &(&1 + 1))
      end
    else
      socket
    end
  end

  # Status/snapshot change on an already-visible row: update in place by dom id.
  defp live_update(socket, ev) do
    if MapSet.member?(socket.assigns.visible, ev.id) do
      case Events.get(ev.id) do
        nil -> socket
        row -> stream_insert(socket, :events, row)
      end
    else
      socket
    end
  end

  defp matches?(filters, ev) do
    camera_ok = blank?(filters.camera) or ev.camera_id == filters.camera
    label_ok = blank?(filters.label) or Map.has_key?(ev.max_scores || %{}, filters.label)
    camera_ok and label_ok and within_dates?(filters, ev.started_at)
  end

  defp within_dates?(filters, %DateTime{} = at) do
    after_from = parse_date(filters.from, ~T[00:00:00])
    before_to = parse_date(filters.to, ~T[23:59:59])

    (is_nil(after_from) or DateTime.compare(at, after_from) != :lt) and
      (is_nil(before_to) or DateTime.compare(at, before_to) != :gt)
  end

  defp blank?(v), do: v in ["", nil]

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

  defp filters_active?(filters) do
    Enum.any?([filters.camera, filters.label, filters.from, filters.to], &(&1 != ""))
  end

  # -- shared design helpers (also used by EventLive) -------------------------

  @doc false
  def label_chip_style(label) do
    {bg, color} =
      case label do
        "person" -> {"var(--hs-accent-soft)", "var(--hs-blue-300)"}
        "car" -> {"var(--hs-success-soft)", "var(--hs-success)"}
        "cat" -> {"rgba(139,92,246,0.14)", "var(--hs-purple-500)"}
        "dog" -> {"rgba(236,72,153,0.14)", "var(--hs-pink-500)"}
        "package" -> {"var(--hs-warning-soft)", "var(--hs-warning)"}
        _ -> {"var(--hs-accent-soft)", "var(--hs-blue-300)"}
      end

    "display: inline-flex; align-items: center; gap: 6px; padding: 3px 10px; " <>
      "border-radius: 6px; font-size: 12px; font-weight: 500; " <>
      "font-variant-numeric: tabular-nums; background: #{bg}; color: #{color};"
  end

  @doc false
  def label_color(label) do
    case label do
      "person" -> "var(--hs-blue-300)"
      "car" -> "var(--hs-success)"
      "cat" -> "var(--hs-purple-500)"
      "dog" -> "var(--hs-pink-500)"
      "package" -> "var(--hs-warning)"
      _ -> "var(--hs-blue-300)"
    end
  end

  @doc false
  def fmt_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%b %-d, %H:%M:%S")

  @doc false
  def fmt_duration(%{started_at: s, ended_at: %DateTime{} = e}) do
    total = max(DateTime.diff(e, s), 0)

    if total >= 60 do
      "#{div(total, 60)}m #{rem(total, 60)}s"
    else
      "#{total}s"
    end
  end

  def fmt_duration(_), do: "—"

  defp fmt_score(score), do: :erlang.float_to_binary(score / 1, decimals: 2)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page={:events}>
      <main style="flex: 1; padding: 20px; max-width: 1080px; width: 100%; margin: 0 auto; box-sizing: border-box;">
        <div style="display: flex; align-items: baseline; gap: 12px; margin-bottom: 14px;">
          <h1 style="margin: 0; font-size: 22px; font-weight: 600; letter-spacing: -0.01em; color: var(--hs-fg-1);">
            Events
          </h1>
          <span class="tnum" style="font-size: 13px; color: var(--hs-fg-3);">
            {@total} {if @total == 1, do: "event", else: "events"}{if filters_active?(@filters),
              do: " match",
              else: ""}
          </span>
        </div>

        <form
          id="event-filters"
          phx-change="filter"
          class="hs-card"
          style="display: flex; flex-wrap: wrap; gap: 12px; align-items: flex-end; padding: 12px 14px; margin-bottom: 16px;"
        >
          <div class="hs-field" style="width: 170px;">
            <label>Camera</label>
            <select name="camera" class="hs-input" style="height: 34px;">
              <option value="">All cameras</option>
              <option :for={c <- @cameras} value={c} selected={@filters.camera == c}>{c}</option>
            </select>
          </div>
          <div class="hs-field" style="width: 150px;">
            <label>Label</label>
            <select name="label" class="hs-input" style="height: 34px;">
              <option value="">All labels</option>
              <option :for={l <- @labels} value={l} selected={@filters.label == l}>{l}</option>
            </select>
          </div>
          <div class="hs-field" style="width: 160px;">
            <label>From</label>
            <input
              type="date"
              name="from"
              class="hs-input"
              value={@filters.from}
              style="height: 34px;"
            />
          </div>
          <div class="hs-field" style="width: 160px;">
            <label>To</label>
            <input type="date" name="to" class="hs-input" value={@filters.to} style="height: 34px;" />
          </div>
          <div style="flex: 1;"></div>
          <button
            :if={filters_active?(@filters)}
            type="button"
            phx-click="clear-filters"
            class="hs-btn hs-btn--ghost hs-btn--sm"
            style="color: var(--hs-fg-2);"
          >
            <span class="ms" style="font-size: 16px;">filter_alt_off</span>Clear filters
          </button>
        </form>

        <div
          id="events-list"
          phx-update="stream"
          style="display: flex; flex-direction: column; gap: 10px;"
        >
          <.link
            :for={{dom_id, event} <- @streams.events}
            navigate={~p"/events/#{event.id}"}
            id={dom_id}
            class="hs-card cairn-event-row"
            style="display: flex; align-items: center; gap: 14px; padding: 10px 14px 10px 10px; cursor: pointer; text-decoration: none; color: inherit;"
          >
            <div style="width: 136px; height: 76px; flex: none; border-radius: 6px; overflow: hidden; background: var(--hs-bg-sunken); display: flex; align-items: center; justify-content: center;">
              <img
                :if={event.snapshot_path}
                src={~p"/media/snapshots/#{event.id}"}
                alt=""
                loading="lazy"
                style="width: 100%; height: 100%; object-fit: cover;"
              />
              <span
                :if={!event.snapshot_path}
                class="ms"
                style="font-size: 22px; color: var(--hs-fg-4);"
              >
                videocam
              </span>
            </div>
            <div style="flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 5px;">
              <div style="display: flex; align-items: center; gap: 10px; flex-wrap: wrap;">
                <span style="font-family: var(--hs-font-mono); font-size: 13px; font-weight: 500; color: var(--hs-fg-1);">
                  {event.camera_id}
                </span>
                <span
                  :if={event.status == :partial}
                  class="hs-badge hs-badge--warning"
                  title="Recording was interrupted"
                >
                  <span class="hs-dot"></span>partial
                </span>
              </div>
              <div
                class="tnum"
                style="display: flex; align-items: center; gap: 14px; font-size: 13px; color: var(--hs-fg-3);"
              >
                <time
                  datetime={DateTime.to_iso8601(event.started_at)}
                  style="display: inline-flex; align-items: center; gap: 5px;"
                >
                  <span class="ms" style="font-size: 15px;">schedule</span>{fmt_time(event.started_at)}
                </time>
                <span style="display: inline-flex; align-items: center; gap: 5px;">
                  <span class="ms" style="font-size: 15px;">timelapse</span>{fmt_duration(event)}
                </span>
              </div>
            </div>
            <div style="display: flex; gap: 6px; flex-wrap: wrap; justify-content: flex-end;">
              <span
                :for={{label, score} <- Map.get(event.labels, "max_scores", %{})}
                class="label-chip"
                style={label_chip_style(label)}
              >
                {label} <span style="opacity: 0.75; font-size: 11px;">{fmt_score(score)}</span>
              </span>
            </div>
            <span class="ms" style="font-size: 20px; color: var(--hs-fg-4); flex: none;">
              chevron_right
            </span>
          </.link>
        </div>

        <div
          :if={@total == 0}
          id="events-empty"
          style="display: flex; flex-direction: column; align-items: center; gap: 10px; padding: 72px 20px; text-align: center;"
        >
          <span class="ms" style="font-size: 46px; color: var(--hs-fg-4);">videocam_off</span>
          <div style="font-size: 15px; font-weight: 500; color: var(--hs-fg-1);">No events match</div>
          <div style="font-size: 13px; color: var(--hs-fg-3);">
            Try widening the date range or removing a filter.
          </div>
          <button
            :if={filters_active?(@filters)}
            phx-click="clear-filters"
            class="hs-btn hs-btn--secondary hs-btn--sm"
            style="margin-top: 6px;"
          >
            Clear filters
          </button>
        </div>

        <nav
          :if={@total > 0}
          id="events-pagination"
          style="display: flex; align-items: center; gap: 10px; margin-top: 16px;"
        >
          <span class="tnum" style="font-size: 13px; color: var(--hs-fg-3);">
            Showing {@showing_from}–{@showing_to} of {@total}
          </span>
          <div style="flex: 1;"></div>
          <button
            phx-click="page"
            phx-value-page={@page - 1}
            disabled={@page <= 1}
            class="hs-btn hs-btn--secondary hs-btn--sm"
          >
            <span class="ms" style="font-size: 16px;">chevron_left</span>Previous
          </button>
          <button
            phx-click="page"
            phx-value-page={@page + 1}
            disabled={!@has_next}
            class="hs-btn hs-btn--secondary hs-btn--sm"
          >
            Next<span class="ms" style="font-size: 16px;">chevron_right</span>
          </button>
        </nav>
      </main>
    </Layouts.app>
    """
  end
end
