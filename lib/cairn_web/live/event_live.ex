defmodule CairnWeb.EventLive do
  @moduledoc """
  Event detail: `<video>` clip playback via the Range-supporting media
  endpoint, labels timeline data (`data-seek` markers for the
  `TimelineSeek` hook), metadata panel. Functional scaffold — visual
  design from the Claude Design handoff.
  """

  use CairnWeb, :live_view

  alias Cairn.Events

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Events.get(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Event not found")
         |> push_navigate(to: ~p"/events")}

      event ->
        {:ok, assign(socket, event: event, page_title: "Event #{String.slice(id, 0, 8)}")}
    end
  end

  defp entries(event), do: Map.get(event.labels, "entries", [])

  defp clip_seconds(%{started_at: s, ended_at: %DateTime{} = e}), do: max(DateTime.diff(e, s), 1)
  defp clip_seconds(_), do: 1

  defp fmt_bytes(nil), do: "—"
  defp fmt_bytes(bytes) when bytes >= 1_048_576, do: "#{Float.round(bytes / 1_048_576, 1)} MB"
  defp fmt_bytes(bytes), do: "#{div(bytes, 1024)} KB"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.link navigate={~p"/events"}>&larr; Events</.link>
      <h1>
        {@event.camera_id}
        <span :if={@event.status == :partial} class="badge-partial">
          partial — recording was interrupted
        </span>
      </h1>

      <video
        id="event-clip"
        controls
        src={~p"/media/events/#{@event.id}"}
        poster={@event.snapshot_path && ~p"/media/snapshots/#{@event.id}"}
      ></video>

      <section id="labels-timeline" phx-hook="TimelineSeek" data-video-id="event-clip">
        <button
          :for={entry <- entries(@event)}
          data-seek={entry["t"]}
          style={"--t: #{entry["t"] / clip_seconds(@event) * 100}%"}
          title={"#{entry["label"]} #{trunc(entry["score"] * 100)}% @ #{entry["t"]}s"}
        >
          {entry["label"]}
        </button>
      </section>

      <dl id="event-meta">
        <dt>Started</dt>
        <dd>
          <time datetime={DateTime.to_iso8601(@event.started_at)}>
            {Calendar.strftime(@event.started_at, "%Y-%m-%d %H:%M:%S")}
          </time>
        </dd>
        <dt>Duration</dt>
        <dd>
          {if @event.ended_at, do: "#{DateTime.diff(@event.ended_at, @event.started_at)}s", else: "—"}
        </dd>
        <dt>Size</dt>
        <dd>{fmt_bytes(@event.bytes)}</dd>
        <dt>Max score</dt>
        <dd>{@event.max_score || "—"}</dd>
        <dt>Status</dt>
        <dd>{@event.status}</dd>
        <dt>Labels</dt>
        <dd>
          <span :for={{label, score} <- Map.get(@event.labels, "max_scores", %{})} class="label-chip">
            {label} {trunc(score * 100)}%
          </span>
        </dd>
        <dt>Event id</dt>
        <dd><code>{@event.id}</code></dd>
      </dl>
    </Layouts.app>
    """
  end
end
