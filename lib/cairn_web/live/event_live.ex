defmodule CairnWeb.EventLive do
  @moduledoc """
  Event detail, styled per the Claude Design handoff: native `<video
  controls>` player, per-label detections timeline (markers `data-seek`,
  `TimelineSeek` hook drives seeking + the playhead line), metadata panel
  with copyable event id.
  """

  use CairnWeb, :live_view

  alias Cairn.Events
  alias CairnWeb.EventsLive

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Events.get(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Event not found")
         |> push_navigate(to: ~p"/events")}

      event ->
        if connected?(socket), do: Cairn.Event.subscribe()
        {:ok, assign(socket, event: event, page_title: "Event #{String.slice(id, 0, 8)}")}
    end
  end

  # Live status: if the event we're viewing is still recording, re-fetch it
  # when it updates/finalizes so the badge, duration, and poster refresh.
  @impl true
  def handle_info({kind, %Cairn.Event{id: id}}, socket)
      when kind in [:event_updated, :event_ended] do
    if id == socket.assigns.event.id do
      case Events.get(id) do
        nil -> {:noreply, socket}
        event -> {:noreply, assign(socket, event: event)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("delete", _params, socket) do
    Events.delete(socket.assigns.event)

    {:noreply,
     socket
     |> put_flash(:info, "Event deleted")
     |> push_navigate(to: ~p"/events")}
  end

  # -- helpers ----------------------------------------------------------------

  defp timeline_rows(event) do
    event.labels
    |> Map.get("entries", [])
    |> Enum.group_by(& &1["label"])
    |> Enum.sort_by(fn {label, _} -> label end)
  end

  defp clip_seconds(%{started_at: s, ended_at: %DateTime{} = e}), do: max(DateTime.diff(e, s), 1)
  defp clip_seconds(_), do: 1

  defp marker_left(entry, duration) do
    pct = min(entry["t"] / duration * 100, 100.0)
    "#{Float.round(pct / 1, 2)}%"
  end

  defp fmt_clock(seconds) do
    s = round(seconds)
    "#{div(s, 60)}:#{s |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}"
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
    <Layouts.app flash={@flash} page={:events}>
      <main style="flex: 1; padding: 20px; max-width: 1180px; width: 100%; margin: 0 auto; box-sizing: border-box;">
        <div style="display: flex; align-items: center; gap: 10px; margin: -4px 0 12px -8px;">
          <.link
            navigate={~p"/events"}
            class="hs-btn hs-btn--ghost hs-btn--sm"
            style="color: var(--hs-fg-2); text-decoration: none;"
          >
            <span class="ms" style="font-size: 17px;">arrow_back</span>Back to events
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
            data-confirm="Delete this event? The clip, snapshot, and index row are removed permanently."
            class="hs-btn hs-btn--ghost hs-btn--sm"
            style="margin-left: auto; color: var(--hs-danger);"
          >
            <span class="ms" style="font-size: 16px;">delete</span>Delete
          </button>
        </div>

        <div style="display: grid; grid-template-columns: minmax(0, 1fr) 300px; gap: 16px; align-items: start;">
          <div style="display: flex; flex-direction: column; gap: 16px; min-width: 0;">
            <div class="hs-card" style="overflow: hidden;">
              <video
                id="event-clip"
                controls
                src={~p"/media/events/#{@event.id}"}
                poster={@event.snapshot_path && ~p"/media/snapshots/#{@event.id}"}
                style="display: block; width: 100%; aspect-ratio: 16 / 9; background: var(--hs-bg-sunken);"
              ></video>
            </div>

            <section
              id="labels-timeline"
              phx-hook="TimelineSeek"
              data-video-id="event-clip"
              data-event-seconds={clip_seconds(@event)}
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
                      data-t={entry["t"]}
                      data-seek={entry["t"]}
                      title={"#{label} #{fmt_score(entry["score"])} at #{fmt_clock(entry["t"])}"}
                      style={
                        "position: absolute; left: #{marker_left(entry, clip_seconds(@event))}; " <>
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
        </div>
      </main>
    </Layouts.app>
    """
  end
end
