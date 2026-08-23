defmodule CairnWeb.EventLive do
  @moduledoc """
  Event detail, styled per the Claude Design handoff: native `<video
  controls>` player under a canvas bbox overlay (`TrackOverlay`, fed by the
  clip's track sidecar), per-label detections timeline (markers `data-seek`,
  `TimelineSeek` hook drives seeking + the playhead line), metadata panel
  with copyable event id, and a tracked-objects panel beneath it.

  The panel lists the objects whose lifetime **overlapped this clip's window**,
  not the ones whose `tracks.event_id` names it: a track that spans two clips
  belongs on both pages, and one that ended between them belongs on neither by
  that column's reckoning. Each of its moments resolves to the clip that
  actually contains it, so a moment seeks this video, navigates to another
  clip, or sits inert — see `Cairn.Tracks.moment_clips/3`. The panel is capped
  at `@max_panel_tracks` objects, oldest first, and says on the page when a
  clip overlapped more than it lists.

  Two query params, both written by links from `CairnWeb.TracksLive` and by
  cross-clip moment rows here: `?track=` focuses one object (it is selected and
  expanded, provided the panel actually loaded that id), and `?t=` seeks the
  player once metadata loads.

  `?track=` doubles as the "this page is part of a track's story" signal: it
  keeps the Tracks nav item lit and points the back button at /tracks. That
  covers the hop from one clip to the next as well as arrival from the browse
  page — both are following one object, which is the journey the back button
  should end.
  """

  use CairnWeb, :live_view

  require Logger

  alias Cairn.Config
  alias Cairn.DataDir
  alias Cairn.Events
  alias Cairn.Tracks
  alias CairnWeb.EventsLive
  alias CairnWeb.TrackMoments

  # The panel is a browsing aid, not an inventory: a day-long clip on a busy
  # camera was in frame of thousands of objects, and every one of them costs a
  # moment list, a `data-objects` entry, a row in the DOM and a re-render on
  # every toggle. Two hundred is more than anyone scrolls; past it the panel
  # says so rather than trying.
  @max_panel_tracks 200

  @impl true
  def mount(%{"id" => id} = params, _session, socket) do
    case Events.get(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Event not found")
         |> push_navigate(to: ~p"/events")}

      event ->
        if connected?(socket), do: Cairn.Event.subscribe()

        # Read per mount, so an operator tuning the number sees it on the
        # next load of an event that already exists — nothing is stored
        # with the offset applied (`Cairn.Config.annotation_offset_ms/2`).
        offset_s = annotation_offset_s(event.camera_id)

        socket =
          assign(socket,
            event: event,
            page_title: "Event #{String.slice(id, 0, 8)}",
            from_tracks?: params["track"] != nil,
            # `?t=` carries detection-clock seconds like every annotation, so
            # a linked seek gets this camera's offset exactly as a rendered
            # marker does — applied at consumption, so links stay portable.
            initial_t: seek_t(initial_t(params["t"]), offset_s),
            annotation_offset_s: offset_s
          )

        # `Events.get/1` stays in both mounts — it decides the 404 — but the
        # panel is three queries and a `File.stat`, and the disconnected render
        # is a frame the socket replaces. It gets an empty panel that says
        # nothing: `@panel_loaded?` withholds the count and the notices, which
        # would otherwise claim "no tracked objects" and "no track file" about
        # a page that has not looked yet.
        {:ok,
         if(connected?(socket),
           do: load_panel(socket, params["track"]),
           else: empty_panel(socket)
         )}
    end
  end

  # Live status: if the event we're viewing is still recording, re-fetch it
  # when it updates/finalizes so the badge, duration, and poster refresh.
  @impl true
  def handle_info({kind, %Cairn.Event{id: id}}, socket)
      when kind in [:event_updated, :event_ended] do
    if id == socket.assigns.event.id do
      # :event_ended is broadcast before the extractor's async finalize +
      # snapshot land, so the immediate re-fetch can miss the finalized status
      # and the snapshot. Schedule a follow-up so the badge and poster settle.
      if kind == :event_ended, do: Process.send_after(self(), {:refresh_event, id}, 1_500)
      {:noreply, refetch(socket, id)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:refresh_event, id}, socket) do
    if id == socket.assigns.event.id,
      # The settle pass, not the per-batch one: it also reloads the panel,
      # because the sidecar and the last of the clip's tracks are written by
      # that same async finalize. `:event_updated` deliberately does not —
      # it fires per detection batch, and the panel is three queries.
      do: {:noreply, socket |> refetch(id) |> reload_panel()},
      else: {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp refetch(socket, id) do
    case Events.get(id) do
      nil -> socket
      event -> assign(socket, event: event)
    end
  end

  @impl true
  def handle_event("delete", _params, socket) do
    case Events.delete(socket.assigns.event) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Event deleted")
         |> push_navigate(to: ~p"/events")}

      {:error, reason} ->
        Logger.warning("event #{socket.assigns.event.id}: delete failed: #{inspect(reason)}")
        {:noreply, put_flash(socket, :error, "Could not delete event")}
    end
  end

  # Both toggles take an object id off the wire, so both check it against the
  # ids this page actually loaded before putting it in a set — an id from
  # anywhere else is dropped rather than accumulated.
  def handle_event("toggle-track", %{"id" => id}, socket) do
    {:noreply, update_set(socket, :selected, id)}
  end

  def handle_event("toggle-moments", %{"id" => id}, socket) do
    {:noreply, update_set(socket, :expanded, id)}
  end

  defp update_set(socket, key, id) do
    if MapSet.member?(socket.assigns.track_ids, id),
      do: assign(socket, key, toggle(socket.assigns[key], id)),
      else: socket
  end

  defp toggle(set, id) do
    if MapSet.member?(set, id), do: MapSet.delete(set, id), else: MapSet.put(set, id)
  end

  # -- tracked-objects panel --------------------------------------------------

  # What the disconnected render carries: enough assigns to draw the page's
  # frame, and `panel_loaded?: false` so it draws no verdict about the panel.
  defp empty_panel(socket) do
    assign(socket,
      objects: [],
      track_ids: MapSet.new(),
      selected: MapSet.new(),
      expanded: MapSet.new(),
      sidecar?: false,
      truncated?: false,
      overlay_objects: "{}",
      overlay_labels: [],
      panel_loaded?: false
    )
  end

  # Mount-time state: `?track=` focuses one object, otherwise every object is
  # visible and none is expanded.
  defp load_panel(socket, focus_id) do
    socket = assign_objects(socket)
    ids = socket.assigns.track_ids

    if focus_id && MapSet.member?(ids, focus_id) do
      assign(socket, selected: MapSet.new([focus_id]), expanded: MapSet.new([focus_id]))
    else
      assign(socket, selected: ids, expanded: MapSet.new())
    end
  end

  # A refresh keeps what the viewer has toggled instead of resetting the panel
  # under them; objects that arrived since the last load default to visible,
  # which is what they would have been at mount.
  defp reload_panel(socket) do
    %{track_ids: known, selected: selected, expanded: expanded} = socket.assigns
    socket = assign_objects(socket)
    ids = socket.assigns.track_ids

    assign(socket,
      selected:
        selected |> MapSet.intersection(ids) |> MapSet.union(MapSet.difference(ids, known)),
      expanded: MapSet.intersection(expanded, ids)
    )
  end

  defp assign_objects(socket) do
    event = socket.assigns.event
    now = DateTime.utc_now()

    # One row past the cap is the whole truncation test: if it comes back, more
    # were overlapping than the panel will list, and the header says so. It
    # costs the same query, where a `count(*)` would cost a second one.
    {tracks, over_cap} =
      event
      |> Tracks.overlapping_event(now, limit: @max_panel_tracks + 1)
      |> Enum.split(@max_panel_tracks)

    moments = Tracks.moments_for(Enum.map(tracks, & &1.id))

    shaped =
      tracks
      |> nth_by_label()
      |> Enum.map(fn {track, nth} ->
        {track, nth, TrackMoments.rows(track, Map.get(moments, track.id, []), now)}
      end)

    # One resolution for the whole panel: every moment of every object, plus
    # the synthetic "ended" rows, against the clips this camera still has.
    clips =
      shaped
      |> Enum.flat_map(fn {_track, _nth, rows} -> Enum.map(rows, & &1.at) end)
      |> Tracks.moment_clips(event.camera_id, event.id)

    offset_s = socket.assigns.annotation_offset_s

    objects =
      Enum.map(shaped, fn {t, nth, rows} -> object(t, nth, rows, clips, event, offset_s) end)

    assign(socket,
      objects: objects,
      track_ids: MapSet.new(objects, & &1.id),
      truncated?: over_cap != [],
      # Stat once per load, never per render. The reload pass re-stats on
      # purpose: an event that was still recording at mount has no sidecar
      # until its finalize writes one.
      sidecar?: sidecar?(event),
      # Encoded once per load, not once per render: `data-objects` changes only
      # when the object set does, while a `toggle-track` re-renders the panel.
      overlay_objects: overlay_objects(objects, event),
      overlay_labels: overlay_labels(objects, event),
      panel_loaded?: true
    )
  end

  # An object's colour is its label's hue varied by `nth`, its ordinal among
  # same-label tracks on this clip. `Tracks.overlapping_event/3` orders by
  # `started_at`, so for one result set the ordinal is fixed, and the row
  # swatch and the canvas box therefore agree — they read the same `nth`.
  #
  # The result set is not fixed for the life of the page. `Cairn.TrackRecorder`
  # is a batch writer, so `reload_panel/1` can land a track *between* two
  # existing rows, and every later same-label object then steps one colour
  # along; retention pruning does the same on a later visit. Selection survives
  # that (it is keyed by id) — the colour is not a stable handle on an object
  # across loads, only within one.
  defp nth_by_label(tracks) do
    {pairs, _counts} =
      Enum.map_reduce(tracks, %{}, fn track, counts ->
        nth = Map.get(counts, track.label, 0)
        {{track, nth}, Map.put(counts, track.label, nth + 1)}
      end)

    pairs
  end

  defp object(track, nth, rows, clips, event, offset_s) do
    %{
      id: track.id,
      label: track.label || "unknown",
      score: fmt_score(track.best_score),
      color: EventsLive.track_color(track.label, nth),
      chip_style: EventsLive.label_chip_style(track.label),
      moments: Enum.map(rows, &moment(&1, clips, event, track.id, offset_s))
    }
  end

  # The three transition-row variants. A moment inside this clip is a
  # `data-t` button the `TimelineSeek` hook rewrites into a pre-roll-corrected
  # seek — the same treatment the detection markers get. A moment inside
  # another surviving clip is a link that carries the object and the offset
  # across. A moment no clip contains is inert.
  defp moment(row, clips, event, object_id, offset_s) do
    base = %{icon: row.icon, text: row.text, suffix: row.suffix, title: row.title}

    case Map.fetch!(clips, row.at) do
      :here ->
        # A moment's time is a detection-clock annotation like every marker,
        # so its seek carries the same camera offset.
        Map.merge(base, %{
          mode: :seek,
          t: seek_t(max(DateTime.diff(row.at, event.started_at), 0), offset_s),
          clock: TrackMoments.fmt_clock(event.started_at, row.at)
        })

      {:other, other_id, seconds} ->
        Map.merge(base, %{
          mode: :link,
          to: ~p"/events/#{other_id}?track=#{object_id}&t=#{seconds}",
          abs: fmt_abs(row.at),
          title: "In another clip — open #{event.camera_id} at #{TrackMoments.fmt_clock(seconds)}"
        })

      :none ->
        Map.merge(base, %{mode: :none, abs: fmt_abs(row.at), suffix: no_clip(row.suffix)})
    end
  end

  defp no_clip(nil), do: "· no clip"
  defp no_clip(suffix), do: suffix <> " · no clip"

  defp sidecar?(%{path: nil}), do: false
  defp sidecar?(%{path: path}), do: File.exists?(DataDir.trackpath_for_clip(path))

  # What the canvas needs that the sidecar does not carry: the colour the panel
  # gave each object, and the label/score for its chip (v1 stores no per-sample
  # score — `best_score` is a track-index column).
  #
  # Keyed by whatever the sidecar keys its tracks by, which is the header's
  # `"identity"` and is the one thing this page cannot cheaply know: reading it
  # means decoding the file, which is the browser's job and already its work.
  # So a label-keyed palette is sent *as well*, one entry per label the event
  # recorded, and the overlay looks up the keying its file declares.
  #
  # Only when the panel found nothing, which is how a label-keyed sidecar
  # arrives here: `Cairn.PresenceRecorder`'s lane runs no tracker, so its
  # clips have no track rows to list. A page that did list objects keeps
  # exactly the map it had.
  defp overlay_objects([], event), do: event |> label_overlay() |> Jason.encode!()

  defp overlay_objects(objects, _event) do
    objects
    |> Map.new(&{&1.id, %{"color" => &1.color, "label" => &1.label, "score" => &1.score}})
    |> Jason.encode!()
  end

  defp label_overlay(event) do
    for {label, score} <- max_scores(event), into: %{} do
      {label,
       %{
         "color" => EventsLive.track_color(label, 0),
         "label" => label,
         "score" => fmt_score(score)
       }}
    end
  end

  # A label-keyed sidecar has no panel row to toggle it from, so its paths are
  # drawn whenever the file is: the labels join the selected set on the way to
  # the overlay without entering `@track_ids`, which is what gates the toggles.
  #
  # `max_scores` and not the sidecar's own labels: the file is unfiltered, so it
  # also holds labels the event never qualified on — below `record:`, or excluded
  # by it. Drawing those would show the viewer more than the event is evidence
  # for, and more than the tracked lane shows, which draws only the objects that
  # earned a row. Parity is the bar D-E5 sets, so the selection is the event's
  # own evidence and nothing else.
  defp overlay_labels([], event), do: event |> max_scores() |> Map.keys() |> Enum.sort()
  defp overlay_labels(_objects, _event), do: []

  # JSON, not a joined string: on the presence lane these keys are model labels,
  # and the protocol permits a comma inside one — a comma-joined list would split
  # it into two keys that match no path. `assets/js/hooks/track_overlay.js` is the
  # only reader, and parses both lanes the same way.
  defp overlay_selected(selected, labels), do: Jason.encode!(Enum.concat(selected, labels))

  defp max_scores(event), do: Map.get(event.labels || %{}, "max_scores", %{})

  # The panel's standing notices, in the order they matter, and only the ones
  # that apply. A clip that is still recording says so rather than complaining
  # about a track file its finalize has not written yet; the cap is orthogonal
  # to both and never stays silent — a list that stops early has to say where.
  defp panel_notes(event, sidecar?, truncated?) do
    Enum.reject([panel_note(event, sidecar?), truncation_note(truncated?)], &is_nil/1)
  end

  # A track earns its row as soon as it qualifies, so a clip still being written
  # already lists what is in frame — but this panel is loaded once and reloaded
  # only when the clip closes (`handle_info/2`), and the boxes come from the
  # sidecar that same finalize writes. So the note promises the reload, not a
  # feed.
  defp panel_note(%{status: :active}, _sidecar?),
    do:
      "Still recording — objects tracked so far are listed. " <>
        "Boxes, and anything tracked since, arrive when the clip closes."

  defp panel_note(_event, false),
    do:
      "We couldn't find this clip's track file, so there are no boxes to draw. Moments still seek."

  defp panel_note(_event, true), do: nil

  defp truncation_note(false), do: nil

  defp truncation_note(true),
    do:
      "Showing the first #{@max_panel_tracks} objects, oldest first — more were in frame during this clip."

  # Solid when the object is selected, a 2px outline when it is not — the same
  # distinction the canvas makes by drawing the box or not.
  @swatch_base "width: 10px; height: 10px; border-radius: 3px; flex: none; "

  defp swatch_style(color, true), do: "#{@swatch_base}background: #{color};"

  defp swatch_style(color, false),
    do:
      "#{@swatch_base}background: transparent; border: 2px solid #{color}; box-sizing: border-box;"

  defp toggle_title(false, _selected?), do: "No boxes — the track file for this clip is missing"
  defp toggle_title(true, true), do: "Hide boxes"
  defp toggle_title(true, false), do: "Show boxes"

  # -- helpers ----------------------------------------------------------------

  # Seconds, because every consumer of it here is a clip time in seconds. A
  # camera that has since left the config reads 0 rather than failing: the
  # event and its clip outlive the camera that made them, and an old event
  # must still render.
  defp annotation_offset_s(camera_id) do
    Config.annotation_offset_ms(Config.Server.get(), camera_id) / 1000
  end

  defp timeline_rows(event) do
    event.labels
    |> Map.get("entries", [])
    |> Enum.group_by(& &1["label"])
    |> Enum.sort_by(fn {label, _} -> label end)
  end

  defp clip_seconds(%{started_at: s, ended_at: %DateTime{} = e}), do: max(DateTime.diff(e, s), 1)
  defp clip_seconds(_), do: 1

  # One shifted time per marker, feeding its position, its seek and its
  # tooltip together — `TimelineSeek` rewrites `left` and `data-seek` from
  # `data-t` once metadata loads, so a shift applied to only some of them
  # would have the dot and the seek disagree.
  #
  # Floored at zero for `label_entry/3`'s reason: this timeline's axis is the
  # EVENT, and a position before its start is not on it. A negative shift can
  # push an early detection off the front, where it sticks at 0:00.
  # Rounded to the precision the entry itself was stored at
  # (`Cairn.PresenceRecorder.label_entry/3`), so a shift does not hand the DOM
  # a float's worth of noise the timeline cannot express anyway.
  defp marker_t(entry, offset_s), do: Float.round(max(entry["t"] + offset_s, 0.0), 1)

  defp marker_left(t, duration) do
    pct = t / duration * 100
    "#{Float.round(min(pct, 100.0) / 1, 2)}%"
  end

  defp fmt_clock(seconds) do
    s = round(seconds)
    "#{div(s, 60)}:#{s |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  defp fmt_abs(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")

  # `?t=` is event-relative seconds, exactly like a marker's `data-t`, so the
  # client applies the same pre-roll correction to it.
  defp initial_t(nil), do: nil

  defp initial_t(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 -> seconds
      _not_a_seek -> nil
    end
  end

  defp seek_t(nil, _offset_s), do: nil

  # Whole results render as integers so a zero-offset camera's seeks keep
  # their exact pre-offset spelling; only a fractional offset adds a decimal.
  defp seek_t(seconds, offset_s) do
    rounded = Float.round(max(seconds + offset_s, 0.0), 1)
    truncated = trunc(rounded)
    if rounded == truncated, do: truncated, else: rounded
  end

  defp fmt_bytes(nil), do: "—"
  defp fmt_bytes(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp fmt_score(nil), do: "—"
  defp fmt_score(score), do: :erlang.float_to_binary(score / 1, decimals: 2)

  defp meta_rows(event) do
    [
      {"Started", EventsLive.fmt_time(event.started_at), :sans},
      {"Ended", if(event.ended_at, do: EventsLive.fmt_time(event.ended_at), else: "—"), :sans},
      {"Duration", EventsLive.fmt_duration(event), :sans},
      {"File size", fmt_bytes(event.bytes), :sans},
      {"Max score", fmt_score(event.max_score), :mono},
      {"Clip path", event.path || "—", :mono_small}
    ]
  end

  defp meta_value_style(:sans), do: "color: var(--hs-fg-1);"
  defp meta_value_style(:mono), do: "color: var(--hs-fg-1); font-family: var(--hs-font-mono);"

  defp meta_value_style(:mono_small),
    do: "color: var(--hs-fg-1); font-family: var(--hs-font-mono); font-size: 11px;"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page={(@from_tracks? && :tracks) || :events}>
      <main style="flex: 1; padding: 20px; max-width: 1180px; width: 100%; margin: 0 auto; box-sizing: border-box;">
        <div style="display: flex; align-items: center; gap: 10px; margin: -4px 0 12px -8px;">
          <.link
            navigate={(@from_tracks? && ~p"/tracks") || ~p"/events"}
            class="hs-btn hs-btn--ghost hs-btn--sm"
            style="color: var(--hs-fg-2); text-decoration: none;"
          >
            <span class="ms" style="font-size: 17px;">arrow_back</span>
            {(@from_tracks? && "Back to tracks") || "Back to events"}
          </.link>

          <span
            :if={@event.status == :active}
            class="hs-badge hs-badge--warning"
            title="This event is still recording"
            style="margin-left: 4px;"
          >
            <span
              class="hs-dot"
              style="animation: cairn-pulse 1.4s ease-in-out infinite;"
            ></span>Recording
          </span>
          <span
            :if={@event.status == :partial}
            class="hs-badge hs-badge--warning"
            title="Recording was interrupted"
            style="margin-left: 4px;"
          >
            <span class="hs-dot"></span>Partial
          </span>

          <button
            phx-click="delete"
            data-confirm="Delete this event? The clip, snapshot, track file, and index row are removed permanently — the tracks themselves stay in the track index."
            class="hs-btn hs-btn--ghost hs-btn--sm"
            style="margin-left: auto; color: var(--hs-danger);"
          >
            <span class="ms" style="font-size: 16px;">delete</span>Delete
          </button>
        </div>

        <div style="display: grid; grid-template-columns: minmax(0, 1fr) 300px; gap: 16px; align-items: start;">
          <div style="display: flex; flex-direction: column; gap: 16px; min-width: 0;">
            <div class="hs-card" style="overflow: hidden;">
              <div style="position: relative;">
                <video
                  id="event-clip"
                  controls
                  src={~p"/media/events/#{@event.id}"}
                  poster={@event.snapshot_path && ~p"/media/snapshots/#{@event.id}"}
                  style="display: block; width: 100%; aspect-ratio: 16 / 9; background: var(--hs-bg-sunken);"
                ></video>
                <div
                  :if={@sidecar?}
                  id="track-overlay-wrap"
                  phx-hook="TrackOverlay"
                  data-video-id="event-clip"
                  data-sidecar-url={~p"/media/events/#{@event.id}/tracks"}
                  data-event-seconds={clip_seconds(@event)}
                  data-annotation-offset={@annotation_offset_s}
                  data-selected={overlay_selected(@selected, @overlay_labels)}
                  data-objects={@overlay_objects}
                  style="position: absolute; inset: 0; pointer-events: none;"
                >
                  <canvas
                    id="track-overlay"
                    phx-update="ignore"
                    style="position: absolute; inset: 0; width: 100%; height: 100%; pointer-events: none;"
                  ></canvas>
                </div>
              </div>
            </div>

            <section
              id="labels-timeline"
              phx-hook="TimelineSeek"
              data-video-id="event-clip"
              data-event-seconds={clip_seconds(@event)}
              data-initial-t={@initial_t}
              class="hs-card"
              style="padding: 16px;"
            >
              <div style="display: flex; align-items: baseline; gap: 10px; margin-bottom: 14px;">
                <h3 style="margin: 0; font-size: 14px; font-weight: 600; color: var(--hs-fg-1);">
                  Detections
                </h3>
                <span style="font-size: 12px; color: var(--hs-fg-3);">click a marker to seek</span>
              </div>
              <div style="display: flex; flex-direction: column; gap: 8px; position: relative;">
                <div
                  :for={{label, entries} <- timeline_rows(@event)}
                  style="display: flex; align-items: center; gap: 12px;"
                >
                  <span style={"width: 72px; flex: none; font-size: 12px; font-weight: 500; text-align: right; color: #{EventsLive.label_color(label)};"}>
                    {label}
                  </span>
                  <div style="flex: 1; height: 26px; position: relative; background: var(--hs-bg-sunken); border-radius: 6px;">
                    <button
                      :for={entry <- entries}
                      data-t={marker_t(entry, @annotation_offset_s)}
                      data-seek={marker_t(entry, @annotation_offset_s)}
                      title={"#{label} #{fmt_score(entry["score"])} at #{fmt_clock(marker_t(entry, @annotation_offset_s))}"}
                      style={
                        "position: absolute; left: #{marker_left(marker_t(entry, @annotation_offset_s), clip_seconds(@event))}; " <>
                          "top: 50%; transform: translate(-50%, -50%); width: 13px; height: 13px; " <>
                          "border-radius: 50%; border: 2px solid var(--hs-bg-surface); cursor: pointer; " <>
                          "padding: 0; background: #{EventsLive.label_color(label)};"
                      }
                    ></button>
                  </div>
                </div>
                <div style="display: flex; align-items: center; gap: 12px;">
                  <span style="width: 72px; flex: none;"></span>
                  <div style="flex: 1; position: relative; height: 16px;">
                    <div
                      data-playhead
                      style="position: absolute; left: 0%; top: -70px; bottom: 14px; width: 2px; background: var(--hs-accent); border-radius: 999px; pointer-events: none;"
                    >
                    </div>
                    <span
                      class="tnum"
                      style="position: absolute; left: 0; font-size: 11px; color: var(--hs-fg-4);"
                    >
                      0:00
                    </span>
                    <span
                      class="tnum"
                      style="position: absolute; left: 50%; transform: translateX(-50%); font-size: 11px; color: var(--hs-fg-4);"
                    >
                      {fmt_clock(clip_seconds(@event) / 2)}
                    </span>
                    <span
                      class="tnum"
                      style="position: absolute; right: 0; font-size: 11px; color: var(--hs-fg-4);"
                    >
                      {fmt_clock(clip_seconds(@event))}
                    </span>
                  </div>
                </div>
              </div>
            </section>
          </div>

          <div style="display: flex; flex-direction: column; gap: 16px; min-width: 0;">
            <aside
              id="event-meta"
              class="hs-card"
              style="padding: 16px; display: flex; flex-direction: column;"
            >
              <div style="display: flex; align-items: center; gap: 10px; padding-bottom: 12px; border-bottom: 1px solid var(--hs-border-2);">
                <span style="font-family: var(--hs-font-mono); font-size: 14px; font-weight: 500; color: var(--hs-fg-1);">
                  {@event.camera_id}
                </span>
                <div style="flex: 1;"></div>
                <span class={[
                  "hs-badge",
                  (@event.status == :partial && "hs-badge--warning") || "hs-badge--success"
                ]}>
                  <span class="hs-dot"></span>{@event.status}
                </span>
              </div>
              <div
                :if={@event.status == :partial}
                style="display: flex; gap: 8px; padding: 10px 0; font-size: 12px; color: var(--hs-warning); line-height: 1.45; border-bottom: 1px solid var(--hs-border-2);"
              >
                <span class="ms" style="font-size: 16px; flex: none; margin-top: 1px;">warning</span>
                Recording was interrupted — the clip may end early.
              </div>
              <div
                :for={{key, value, font} <- meta_rows(@event)}
                class="tnum"
                style="display: flex; align-items: baseline; gap: 12px; padding: 9px 0; border-bottom: 1px solid var(--hs-border-2); font-size: 13px;"
              >
                <span style="color: var(--hs-fg-3); width: 84px; flex: none;">{key}</span>
                <span style={"word-break: break-all; " <> meta_value_style(font)}>{value}</span>
              </div>
              <div style="display: flex; align-items: center; gap: 8px; padding-top: 10px;">
                <span style="font-family: var(--hs-font-mono); font-size: 11px; color: var(--hs-fg-4); word-break: break-all; flex: 1;">
                  {@event.id}
                </span>
                <button
                  id="copy-event-id"
                  phx-hook="CopyText"
                  data-copy={@event.id}
                  title="Copy event id"
                  class="hs-btn hs-btn--ghost hs-btn--sm hs-btn--icon"
                  style="width: 28px; color: var(--hs-fg-3);"
                >
                  <span class="ms" style="font-size: 16px;">content_copy</span>
                </button>
              </div>
            </aside>

            <section
              id="tracked-objects"
              class="hs-card"
              style="padding: 16px; display: flex; flex-direction: column;"
            >
              <div style="display: flex; align-items: baseline; gap: 8px;">
                <h3 style="margin: 0; font-size: 14px; font-weight: 600; color: var(--hs-fg-1);">
                  Tracked objects
                </h3>
                <span
                  :if={@panel_loaded?}
                  class="tnum"
                  style="font-size: 12px; color: var(--hs-fg-3);"
                >
                  {length(@objects)}
                </span>
              </div>
              <div style="font-size: 12px; color: var(--hs-fg-3); margin: 2px 0 10px;">
                click a moment to seek
              </div>

              <div
                :for={note <- (@panel_loaded? && panel_notes(@event, @sidecar?, @truncated?)) || []}
                style="display: flex; gap: 7px; padding: 8px 10px; margin-bottom: 10px; border-radius: 6px; background: var(--hs-bg-sunken); font-size: 12px; color: var(--hs-fg-2); line-height: 1.45;"
              >
                <span
                  class="ms"
                  style="font-size: 15px; flex: none; margin-top: 1px; color: var(--hs-fg-3);"
                >
                  info
                </span>
                <span>{note}</span>
              </div>

              <div
                :if={@objects != []}
                id="track-moments"
                phx-hook="TimelineSeek"
                data-video-id="event-clip"
                data-event-seconds={clip_seconds(@event)}
                style="display: flex; flex-direction: column;"
              >
                <div
                  :for={obj <- @objects}
                  id={"track-object-#{obj.id}"}
                  style={"border-top: 1px solid var(--hs-border-2); padding: 9px 0; opacity: #{if MapSet.member?(@selected, obj.id), do: "1", else: "0.55"};"}
                >
                  <div style="display: flex; align-items: center; gap: 8px;">
                    <span style={swatch_style(obj.color, MapSet.member?(@selected, obj.id))}></span>
                    <span class="label-chip" style={obj.chip_style}>
                      {obj.label} <span style="opacity: 0.75; font-size: 11px;">{obj.score}</span>
                    </span>
                    <div style="flex: 1;"></div>
                    <button
                      phx-click="toggle-track"
                      phx-value-id={obj.id}
                      disabled={!@sidecar?}
                      title={toggle_title(@sidecar?, MapSet.member?(@selected, obj.id))}
                      class="hs-btn hs-btn--ghost hs-btn--sm hs-btn--icon"
                      style={"width: 26px; height: 26px; opacity: #{if @sidecar?, do: "1", else: "0.4"}; color: #{if MapSet.member?(@selected, obj.id), do: "var(--hs-fg-2)", else: "var(--hs-fg-4)"};"}
                    >
                      <span class="ms" style="font-size: 17px;">
                        {if MapSet.member?(@selected, obj.id),
                          do: "visibility",
                          else: "visibility_off"}
                      </span>
                    </button>
                    <button
                      phx-click="toggle-moments"
                      phx-value-id={obj.id}
                      title="Moments"
                      class="hs-btn hs-btn--ghost hs-btn--sm hs-btn--icon"
                      style="width: 26px; height: 26px; color: var(--hs-fg-3);"
                    >
                      <span class="ms" style="font-size: 17px;">
                        {if MapSet.member?(@expanded, obj.id), do: "expand_less", else: "expand_more"}
                      </span>
                    </button>
                  </div>

                  <div
                    :if={MapSet.member?(@expanded, obj.id)}
                    style="display: flex; flex-direction: column; gap: 1px; margin-top: 7px;"
                  >
                    <div :for={m <- obj.moments}>
                      <button
                        :if={m.mode == :seek}
                        data-t={m.t}
                        class="cairn-moment"
                        style="display: flex; align-items: center; gap: 8px; border: none; background: transparent; border-radius: 6px; padding: 4px 6px; cursor: pointer; text-align: left; font-family: var(--hs-font-sans); width: 100%; box-sizing: border-box;"
                      >
                        <span class="ms" style="font-size: 15px; color: var(--hs-fg-3); flex: none;">
                          {m.icon}
                        </span>
                        <span
                          class="tnum"
                          style="font-family: var(--hs-font-mono); font-size: 12px; color: var(--hs-fg-2); width: 32px; flex: none;"
                        >
                          {m.clock}
                        </span>
                        <span style="font-size: 12px; color: var(--hs-fg-2);">{m.text}</span>
                        <span
                          :if={m.suffix}
                          title={m.title}
                          style="font-size: 11px; color: var(--hs-fg-4);"
                        >
                          {m.suffix}
                        </span>
                      </button>

                      <.link
                        :if={m.mode == :link}
                        navigate={m.to}
                        title={m.title}
                        class="cairn-moment"
                        style="display: flex; align-items: center; gap: 8px; border-radius: 6px; padding: 4px 6px; text-decoration: none;"
                      >
                        <span class="ms" style="font-size: 15px; color: var(--hs-fg-3); flex: none;">
                          {m.icon}
                        </span>
                        <span
                          class="tnum"
                          style="font-family: var(--hs-font-mono); font-size: 12px; color: var(--hs-blue-300); width: 56px; flex: none;"
                        >
                          {m.abs}
                        </span>
                        <span style="font-size: 12px; color: var(--hs-blue-300);">{m.text}</span>
                        <span :if={m.suffix} style="font-size: 11px; color: var(--hs-fg-4);">
                          {m.suffix}
                        </span>
                        <div style="flex: 1;"></div>
                        <span
                          class="ms"
                          style="font-size: 14px; color: var(--hs-blue-300); flex: none;"
                        >
                          arrow_outward
                        </span>
                      </.link>

                      <div
                        :if={m.mode == :none}
                        style="display: flex; align-items: center; gap: 8px; padding: 4px 6px; opacity: 0.6;"
                      >
                        <span class="ms" style="font-size: 15px; color: var(--hs-fg-4); flex: none;">
                          {m.icon}
                        </span>
                        <span
                          class="tnum"
                          style="font-family: var(--hs-font-mono); font-size: 12px; color: var(--hs-fg-3); width: 56px; flex: none;"
                        >
                          {m.abs}
                        </span>
                        <span style="font-size: 12px; color: var(--hs-fg-3);">{m.text}</span>
                        <span
                          :if={m.suffix}
                          title={m.title}
                          style="font-size: 11px; color: var(--hs-fg-4);"
                        >
                          {m.suffix}
                        </span>
                      </div>
                    </div>

                    <div
                      :if={obj.moments == []}
                      style="font-size: 12px; color: var(--hs-fg-4); padding: 4px 6px;"
                    >
                      No moments — it appeared and was evicted.
                    </div>
                  </div>
                </div>
              </div>

              <div
                :if={@panel_loaded? and @objects == []}
                id="tracked-objects-empty"
                style="display: flex; flex-direction: column; align-items: center; gap: 8px; padding: 22px 10px; text-align: center;"
              >
                <span class="ms" style="font-size: 34px; color: var(--hs-fg-4);">route</span>
                <div style="font-size: 13px; font-weight: 500; color: var(--hs-fg-1);">
                  No tracked objects
                </div>
                <div style="font-size: 12px; color: var(--hs-fg-3); line-height: 1.45;">
                  Its camera runs no tracker, this clip predates tracking, or its tracks have aged out.
                </div>
              </div>
            </section>
          </div>
        </div>
      </main>
    </Layouts.app>
    """
  end
end
