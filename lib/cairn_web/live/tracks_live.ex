defmodule CairnWeb.TracksLive do
  @moduledoc """
  Track browser, styled per the Claude Design handoff (round two). Answers the
  question the event browser cannot: *what did the system see*, recorded or not.

  Functional contracts preserved: `phx-change="filter"` form
  (camera/label/zone/from/to), container `#tracks-list`, `phx-click="page"`
  pagination, row link → `/events/:event_id?track=:track_id`.

  Every row expands in place to show its moments. That expansion is a plain
  `<details>`: no `phx-click`, no server-held open/closed state, and it works
  for the rows that have nowhere to navigate to — the tracks nothing recorded,
  which are the majority and the reason this page exists.
  """

  use CairnWeb, :live_view

  alias Cairn.Tracks
  alias CairnWeb.EventsLive
  alias CairnWeb.TrackMoments

  @page_size 25

  # How many zone chips a row shows before collapsing the rest into "+N".
  @zone_chips 2

  # `?page=` is a URL knob, and an offset SQLite services by walking the index:
  # the deeper the page, the longer the walk. 10 000 pages of 25 is 250 000
  # rows in, past the end of any list a person is reading, so beyond this the
  # number is pinned rather than obeyed.
  @max_page 10_000

  @impl true
  def mount(_params, _session, socket) do
    # This page renders twice — once for the HTTP response, once on the socket
    # — and only the second is ever read: an NVR serves operators, not
    # crawlers, so the dead frame exists to be replaced. Everything that costs
    # a query waits for `connected?/1`, and `@loaded?` marks which frame this
    # is so the empty one does not announce a count it never took.
    connected? = connected?(socket)

    {:ok,
     assign(socket,
       page_title: "Tracks",
       loaded?: connected?,
       cameras: camera_ids(),
       labels: (connected? && Tracks.known_labels()) || [],
       zones: (connected? && Tracks.known_zones()) || []
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = filters_from(params)
    page = page_from(params)

    # This callback runs on the disconnected mount as well as the connected
    # one, and a live patch (filter, page) can only arrive on a connected
    # socket — so the second branch is the dead frame and nothing else, and its
    # assigns are placeholders for a render that is about to be replaced.
    socket =
      if socket.assigns.loaded?,
        do: assign_rows(socket, filters, page),
        else:
          assign(socket,
            filters: filters,
            page: page,
            total: 0,
            showing_from: 0,
            showing_to: 0,
            has_next: false,
            rows: []
          )

    {:noreply, socket}
  end

  defp filters_from(params) do
    %{
      camera: params["camera"] || "",
      label: params["label"] || "",
      zone: params["zone"] || "",
      from: params["from"] || "",
      to: params["to"] || ""
    }
  end

  defp page_from(params) do
    case Integer.parse(params["page"] || "1") do
      {n, ""} when n >= 1 -> min(n, @max_page)
      _ -> 1
    end
  end

  defp assign_rows(socket, filters, page) do
    result =
      Tracks.list(
        camera: filters.camera,
        label: filters.label,
        zone: filters.zone,
        from: parse_date(filters.from, ~T[00:00:00]),
        to: parse_date(filters.to, ~T[23:59:59]),
        page: page,
        page_size: @page_size
      )

    # One clock for the whole render: a live track's elapsed time and its
    # ongoing stationary run are both measured against it, and both are computed
    # here rather than ticked — the design asks for a duration, not a stopwatch.
    now = DateTime.utc_now()
    links = Tracks.first_overlapping_event_ids(result.tracks, now)
    moments = Tracks.moments_for(Enum.map(result.tracks, & &1.id))

    assign(socket,
      filters: filters,
      page: result.page,
      total: result.total,
      showing_from: (result.page - 1) * @page_size + 1,
      showing_to: (result.page - 1) * @page_size + length(result.tracks),
      has_next: result.page * @page_size < result.total,
      rows: Enum.map(result.tracks, &row(&1, links, moments, now))
    )
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply, push_patch(socket, to: ~p"/tracks?#{filter_query(params, 1)}")}
  end

  def handle_event("page", %{"page" => page}, socket) do
    {:noreply, push_patch(socket, to: ~p"/tracks?#{filter_query(socket.assigns.filters, page)}")}
  end

  def handle_event("clear-filters", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/tracks")}
  end

  # -- row shaping ------------------------------------------------------------

  defp row(track, links, moments, now) do
    event_id = Map.get(links, track.id)
    live? = is_nil(track.ended_at)
    zones = track.zones || []

    %{
      id: track.id,
      dom_id: "track-#{track.id}",
      label: track.label || "unknown",
      chip_style: EventsLive.label_chip_style(track.label),
      score: fmt_score(track.best_score),
      camera: track.camera_id,
      started_at: track.started_at,
      time: EventsLive.fmt_time(track.started_at),
      # A live track's duration is how long it has been in frame so far, which
      # is `fmt_duration/1` with `now` standing in for the end it does not have.
      duration:
        EventsLive.fmt_duration(%{started_at: track.started_at, ended_at: end_or(track, now)}),
      zones: Enum.take(zones, @zone_chips),
      zone_more: if(length(zones) > @zone_chips, do: "+#{length(zones) - @zone_chips}"),
      no_zones?: zones == [],
      live?: live?,
      event_id: event_id,
      # "no clip" is the browse-level state for every unlinked row; a live row
      # says "live" instead, which is the more useful of the two.
      note: if(is_nil(event_id) and not live?, do: "no clip"),
      moments: moment_rows(track, Map.get(moments, track.id, []), now),
      # Only unlinked rows explain themselves. `event_id` on the row names a
      # clip that once held this track, so a row carrying one that no longer
      # resolves is read as pruned. It is not a proof: a track that ends on a
      # stream reset can be written with a nil `event_id` while a clip was in
      # fact recording, and reads as "never recorded" here. The two hints are a
      # best guess at browse level, which is why the row surface says only "no
      # clip" either way.
      no_clip_hint:
        cond do
          event_id != nil -> nil
          track.event_id != nil -> "clip expired — moments only"
          true -> "never recorded — moments only"
        end
    }
  end

  defp end_or(%{ended_at: nil}, now), do: now
  defp end_or(%{ended_at: ended_at}, _now), do: ended_at

  # `CairnWeb.TrackMoments` shapes the moments — collapsing, glyphs, end-reason
  # gloss — and leaves the clock to whoever is rendering them. Here that is the
  # offset from the track's own start, which is the only origin a row on this
  # page has; the event panel measures the same moments from its clip instead.
  defp moment_rows(track, moments, now) do
    track
    |> TrackMoments.rows(moments, now)
    |> Enum.map(&Map.put(&1, :clock, TrackMoments.fmt_clock(track.started_at, &1.at)))
  end

  # -- formatting -------------------------------------------------------------

  defp fmt_score(nil), do: "—"
  defp fmt_score(score), do: :erlang.float_to_binary(score / 1, decimals: 2)

  # -- params -----------------------------------------------------------------

  # Both shapes of "the current filters" pass through here: the form's params
  # (string keys) and the `@filters` assign (atom keys).
  @filter_keys [camera: "camera", label: "label", zone: "zone", from: "from", to: "to"]

  defp filter_query(params, page) do
    @filter_keys
    |> Enum.map(fn {key, name} -> {name, params[name] || params[key] || ""} end)
    |> Enum.reject(fn {_name, value} -> value == "" end)
    |> Map.new()
    |> Map.put("page", page)
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
    Enum.any?(
      [filters.camera, filters.label, filters.zone, filters.from, filters.to],
      &(&1 != "")
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page={:tracks}>
      <main style="flex: 1; padding: 20px; max-width: 1080px; width: 100%; margin: 0 auto; box-sizing: border-box;">
        <div style="display: flex; align-items: baseline; gap: 12px; margin-bottom: 14px;">
          <h1 style="margin: 0; font-size: 22px; font-weight: 600; letter-spacing: -0.01em; color: var(--hs-fg-1);">
            Tracks
          </h1>
          <span :if={@loaded?} class="tnum" style="font-size: 13px; color: var(--hs-fg-3);">
            {@total} {if @total == 1, do: "track", else: "tracks"}{if filters_active?(@filters),
              do: " match",
              else: ""}
          </span>
        </div>

        <form
          id="track-filters"
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
          <div class="hs-field" style="width: 150px;">
            <label>Zone</label>
            <select name="zone" class="hs-input" style="height: 34px;">
              <option value="">All zones</option>
              <option :for={z <- @zones} value={z} selected={@filters.zone == z}>{z}</option>
            </select>
          </div>
          <%!-- A date input reports every keystroke, and each one is a patch that
                re-runs the count and the page query — a `json_each` walk of the
                whole table when a zone is picked. The selects fire once per
                choice and need no such guard. --%>
          <div class="hs-field" style="width: 160px;">
            <label>From</label>
            <input
              type="date"
              name="from"
              class="hs-input"
              phx-debounce="300"
              value={@filters.from}
              style="height: 34px;"
            />
          </div>
          <div class="hs-field" style="width: 160px;">
            <label>To</label>
            <input
              type="date"
              name="to"
              class="hs-input"
              phx-debounce="300"
              value={@filters.to}
              style="height: 34px;"
            />
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

        <%!-- Every row's moment list ships closed but present: `<details>` needs
              no round trip to open, which is the point on a page whose rows
              mostly have nowhere to navigate. What keeps that honest is a
              writer-side cap — `Cairn.TrackRecorder`'s `@max_moments_per_track`
              (32) refuses a track's 33rd moment — so a full page is at most 25 ×
              (32 + the synthetic "ended" row) list items, not "however long the
              track was". The cap binds what the recorder writes, not the table:
              a track id re-offered across a crash flush inserts its moments
              twice (see `Cairn.Tracks.insert_batch/1`), so read 32 as the
              shape of a row, not as a database invariant. --%>
        <div id="tracks-list" style="display: flex; flex-direction: column; gap: 10px;">
          <details
            :for={row <- @rows}
            id={row.dom_id}
            class="hs-card cairn-track-row"
            style="display: flex; flex-direction: column;"
          >
            <summary style="display: flex; align-items: center; gap: 14px; padding: 11px 14px;">
              <div style="width: 128px; flex: none; display: flex;">
                <span class="label-chip" style={row.chip_style}>
                  {row.label} <span style="opacity: 0.75; font-size: 11px;">{row.score}</span>
                </span>
              </div>
              <span style="font-family: var(--hs-font-mono); font-size: 13px; font-weight: 500; color: var(--hs-fg-1); width: 88px; flex: none;">
                {row.camera}
              </span>
              <time
                datetime={DateTime.to_iso8601(row.started_at)}
                class="tnum"
                style="display: inline-flex; align-items: center; gap: 5px; font-size: 13px; color: var(--hs-fg-3); width: 138px; flex: none;"
              >
                <span class="ms" style="font-size: 15px;">schedule</span>{row.time}
              </time>
              <span
                class="tnum"
                style="display: inline-flex; align-items: center; gap: 5px; font-size: 13px; color: var(--hs-fg-3); width: 78px; flex: none;"
              >
                <span class="ms" style="font-size: 15px;">timelapse</span>{row.duration}
              </span>
              <div style="display: flex; align-items: center; gap: 5px; min-width: 0;">
                <span
                  :for={zone <- row.zones}
                  style="font-family: var(--hs-font-mono); font-size: 11px; color: var(--hs-fg-2); background: var(--hs-bg-sunken); border-radius: 4px; padding: 2px 6px;"
                >
                  {zone}
                </span>
                <span :if={row.zone_more} style="font-size: 11px; color: var(--hs-fg-4);">
                  {row.zone_more}
                </span>
                <span :if={row.no_zones?} style="font-size: 12px; color: var(--hs-fg-4);">—</span>
              </div>
              <div style="flex: 1;"></div>
              <span :if={row.live?} class="hs-badge hs-badge--success">
                <span class="hs-dot" style="animation: cairn-pulse 1.4s ease-in-out infinite;"></span>live
              </span>
              <span :if={row.note} style="font-size: 12px; color: var(--hs-fg-4); flex: none;">
                {row.note}
              </span>
              <.link
                :if={row.event_id}
                navigate={~p"/events/#{row.event_id}?track=#{row.id}"}
                title="Open the clip this track appears in"
                style="display: inline-flex; color: var(--hs-fg-4); flex: none;"
              >
                <span class="ms" style="font-size: 20px;">chevron_right</span>
              </.link>
              <span
                :if={!row.event_id}
                class="ms cairn-disclosure--more"
                style="font-size: 20px; color: var(--hs-fg-4); flex: none;"
              >
                expand_more
              </span>
              <span
                :if={!row.event_id}
                class="ms cairn-disclosure--less"
                style="font-size: 20px; color: var(--hs-fg-4); flex: none;"
              >
                expand_less
              </span>
            </summary>
            <div style="border-top: 1px solid var(--hs-border-2); padding: 8px 14px 10px; display: flex; flex-direction: column; gap: 2px;">
              <div
                :for={moment <- row.moments}
                style="display: flex; align-items: center; gap: 8px; padding: 3px 0;"
              >
                <span class="ms" style="font-size: 15px; color: var(--hs-fg-3); flex: none;">
                  {moment.icon}
                </span>
                <span
                  class="tnum"
                  style="font-family: var(--hs-font-mono); font-size: 12px; color: var(--hs-fg-2); width: 46px; flex: none;"
                >
                  {moment.clock}
                </span>
                <span style="font-size: 12px; color: var(--hs-fg-2);">{moment.text}</span>
                <span
                  :if={moment.suffix}
                  title={moment.title}
                  style="font-size: 11px; color: var(--hs-fg-4);"
                >
                  {moment.suffix}
                </span>
              </div>
              <div
                :if={row.moments == []}
                style="font-size: 12px; color: var(--hs-fg-4); padding: 3px 0;"
              >
                No moments recorded.
              </div>
              <div style="display: flex; align-items: center; gap: 8px; margin-top: 6px;">
                <span style="font-family: var(--hs-font-mono); font-size: 11px; color: var(--hs-fg-4); word-break: break-all;">
                  {row.id}
                </span>
                <div style="flex: 1;"></div>
                <span :if={row.no_clip_hint} style="font-size: 11px; color: var(--hs-fg-4);">
                  {row.no_clip_hint}
                </span>
              </div>
            </div>
          </details>
        </div>

        <div
          :if={@loaded? and @total == 0}
          id="tracks-empty"
          style="display: flex; flex-direction: column; align-items: center; gap: 10px; padding: 72px 20px; text-align: center;"
        >
          <span class="ms" style="font-size: 46px; color: var(--hs-fg-4);">route</span>
          <div style="font-size: 15px; font-weight: 500; color: var(--hs-fg-1);">No tracks match</div>
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
          id="tracks-pagination"
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
