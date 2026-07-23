defmodule CairnWeb.DashboardLive do
  @moduledoc """
  Camera grid (functional scaffold — visual design comes from the Claude
  Design handoff, see `docs/design-handoff.md`).

  Data contract:

    * `@cameras` — `[%Cairn.Config.Camera{}]` from the active config
    * `@statuses` — `%{camera_id => %{status: atom, probe: map | nil}}`,
      live-updated via `Cairn.CameraStatus.subscribe/0`
    * each tile hosts `<video phx-hook="MsePlayer" data-camera-id=...>`;
      the hook speaks the `camera:{id}` channel and falls back to
      `/hls/{id}/index.m3u8`
  """

  use CairnWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Cairn.CameraStatus.subscribe()
      Cairn.Event.subscribe()
      Cairn.Retention.subscribe()
    end

    {:ok,
     assign(socket,
       page_title: "Dashboard",
       cameras: Cairn.Config.Server.get().cameras,
       statuses: Cairn.CameraStatus.all(),
       live_events: %{},
       transports: %{},
       disk_alert: disk_alert()
     )}
  end

  defp disk_alert do
    Cairn.Retention.alert()
  catch
    :exit, _ -> %{active: false}
  end

  @impl true
  def handle_event("toggle-transport", %{"camera" => camera_id}, socket) do
    {:noreply,
     update(socket, :transports, fn transports ->
       Map.update(transports, camera_id, :webrtc, fn
         :mse -> :webrtc
         :webrtc -> :mse
       end)
     end)}
  end

  @impl true
  def handle_info({:camera_status, camera_id, info}, socket) do
    {:noreply, update(socket, :statuses, &Map.put(&1, camera_id, info))}
  end

  def handle_info({kind, %Cairn.Event{} = event}, socket)
      when kind in [:event_started, :event_updated] do
    {:noreply, update(socket, :live_events, &Map.put(&1, event.camera_id, true))}
  end

  def handle_info({:event_ended, %Cairn.Event{} = event}, socket) do
    {:noreply, update(socket, :live_events, &Map.delete(&1, event.camera_id))}
  end

  def handle_info({:disk_alert, alert}, socket) do
    {:noreply, assign(socket, disk_alert: alert)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <aside :if={@disk_alert.active} id="disk-alert" role="alert">
        Low disk space ({@disk_alert[:free_mb]} MB free, floor {@disk_alert[:threshold_mb]} MB) —
        emergency cleanup is deleting oldest events.
      </aside>

      <section id="camera-grid" class="grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-3">
        <p :if={@cameras == []} id="empty-state">
          No cameras configured. Add cameras to <code>config.yml</code> and reload.
        </p>
        <article :for={cam <- @cameras} id={"camera-tile-#{cam.id}"} class="rounded border p-2">
          <header class="flex items-center justify-between">
            <h2>{cam.id}</h2>
            <span id={"camera-status-#{cam.id}"} data-status={status(@statuses, cam.id)}>
              {status(@statuses, cam.id)}
            </span>
            <span
              :if={@live_events[cam.id]}
              id={"camera-live-event-#{cam.id}"}
              class="live-event-marker"
            >
              ● REC
            </span>
          </header>
          <video
            id={"camera-video-#{cam.id}-#{transport(@transports, cam.id)}"}
            phx-hook={
              if transport(@transports, cam.id) == :webrtc, do: "WebrtcPlayer", else: "MsePlayer"
            }
            phx-update="ignore"
            data-camera-id={cam.id}
            data-hls-url={~p"/hls/#{cam.id}/index.m3u8"}
            muted
            autoplay
            playsinline
            class="mt-2 w-full bg-black"
          ></video>
          <button
            id={"camera-transport-#{cam.id}"}
            phx-click="toggle-transport"
            phx-value-camera={cam.id}
          >
            {if transport(@transports, cam.id) == :webrtc,
              do: "Low latency (WebRTC)",
              else: "Standard (MSE)"}
          </button>
        </article>
      </section>
    </Layouts.app>
    """
  end

  defp status(statuses, camera_id) do
    statuses |> Map.get(camera_id, %{}) |> Map.get(:status, :unknown)
  end

  defp transport(transports, camera_id), do: Map.get(transports, camera_id, :mse)
end
