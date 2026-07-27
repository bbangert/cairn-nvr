defmodule CairnWeb.DashboardLive do
  @moduledoc """
  Camera grid, styled per the Claude Design handoff (docs/design-handoff.md
  round-trip). Functional contracts preserved: tile/status/video ids,
  `data-status`, MsePlayer/WebrtcPlayer hooks, `toggle-transport` events.

  Data contract:

    * `@cameras` — `[%Cairn.Config.Camera{}]` from the active config
    * `@statuses` — `%{camera_id => %{status: atom, probe: map | nil}}`,
      live-updated via `Cairn.CameraStatus.subscribe/0`
    * `@live_events` — `%{camera_id => true}` from the `"events"` topic
    * `@disk_alert` — from `Cairn.Retention`
  """

  use CairnWeb, :live_view

  @status_meta %{
    connecting: %{label: "Connecting", color: "var(--hs-warning)", pulse: true},
    running: %{label: "Running", color: "var(--hs-success)"},
    backoff: %{
      label: "Unreachable",
      color: "var(--hs-danger)",
      pulse: true,
      icon: "wifi_off",
      msg: "We can't reach this camera — retrying every 10 s."
    },
    stalled: %{
      label: "Stalled",
      color: "var(--hs-state-on)",
      icon: "motion_photos_paused",
      msg: "The stream stopped sending frames. We're restarting it."
    },
    transcode_unavailable: %{
      label: "Transcode unavailable",
      color: "var(--hs-danger)",
      icon: "sync_problem",
      msg:
        "This stream needs transcoding but the hardware encoder isn't available. " <>
          "Install it or disable transcode for this camera."
    },
    unknown: %{label: "Unknown", color: "var(--hs-fg-3)"}
  }

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
  def handle_event("toggle-transport", %{"camera" => camera_id} = params, socket) do
    {:noreply,
     update(socket, :transports, fn transports ->
       case params["transport"] do
         "mse" ->
           Map.put(transports, camera_id, :mse)

         "webrtc" ->
           Map.put(transports, camera_id, :webrtc)

         _ ->
           Map.update(transports, camera_id, :webrtc, fn
             :mse -> :webrtc
             :webrtc -> :mse
           end)
       end
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

  # The `"events"` topic also carries the per-object track lifecycle, and
  # gains kinds over time; the grid only cares about whether a camera has a
  # live event.
  def handle_info(_msg, socket), do: {:noreply, socket}

  # -- view helpers -----------------------------------------------------------

  defp status(statuses, camera_id) do
    statuses |> Map.get(camera_id, %{}) |> Map.get(:status, :unknown)
  end

  defp meta(status), do: Map.get(@status_meta, status, @status_meta.unknown)

  defp transport(transports, camera_id), do: Map.get(transports, camera_id, :mse)

  defp summary(cameras, statuses, live_events) do
    total = length(cameras)
    running = Enum.count(cameras, &(status(statuses, &1.id) == :running))
    recording = map_size(live_events)

    base = "#{running} of #{total} running"
    if recording > 0, do: "#{base} · #{recording} recording", else: base
  end

  defp seg_style(true) do
    "border: none; cursor: pointer; padding: 4px 12px; border-radius: 999px; " <>
      "font-size: 11px; font-weight: 600; font-family: var(--hs-font-sans); " <>
      "background: var(--hs-bg-raised); color: var(--hs-fg-1); box-shadow: var(--hs-shadow-xs);"
  end

  defp seg_style(false) do
    "border: none; cursor: pointer; padding: 4px 12px; border-radius: 999px; " <>
      "font-size: 11px; font-weight: 600; font-family: var(--hs-font-sans); " <>
      "background: transparent; color: var(--hs-fg-4);"
  end

  defp tile_style(true) do
    "overflow: hidden; display: flex; flex-direction: column; border-color: var(--hs-red-500); " <>
      "box-shadow: 0 0 0 1px #e5484d, 0 0 18px rgba(229, 72, 77, 0.35);"
  end

  defp tile_style(false), do: "overflow: hidden; display: flex; flex-direction: column;"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page={:dashboard}>
      <aside
        :if={@disk_alert.active}
        id="disk-alert"
        role="alert"
        style="display: flex; align-items: center; gap: 12px; padding: 10px 20px; background: var(--hs-warning-soft); border-bottom: 1px solid var(--hs-border-1); color: var(--hs-warning); flex: none;"
      >
        <span class="ms" style="font-size: 20px; flex: none;">hard_drive</span>
        <div style="font-size: 13px; font-weight: 500; color: var(--hs-fg-1);">
          Low disk space — emergency cleanup is deleting the oldest events.
        </div>
        <div style="flex: 1;"></div>
        <span
          class="tnum"
          style="font-family: var(--hs-font-mono); font-size: 12px; color: var(--hs-warning); font-weight: 500;"
        >
          {@disk_alert[:free_mb]} MB free
        </span>
      </aside>

      <main style="flex: 1; padding: 20px; max-width: 1440px; width: 100%; margin: 0 auto; box-sizing: border-box;">
        <div style="display: flex; align-items: baseline; gap: 12px; margin-bottom: 16px;">
          <h1 style="margin: 0; font-size: 22px; font-weight: 600; letter-spacing: -0.01em; color: var(--hs-fg-1);">
            Cameras
          </h1>
          <span style="font-size: 13px; color: var(--hs-fg-3);">
            {summary(@cameras, @statuses, @live_events)}
          </span>
        </div>

        <div
          :if={@cameras == []}
          id="empty-state"
          style="display: flex; flex-direction: column; align-items: center; gap: 10px; padding: 72px 20px; text-align: center;"
        >
          <span class="ms" style="font-size: 46px; color: var(--hs-fg-4);">videocam</span>
          <div style="font-size: 15px; font-weight: 500; color: var(--hs-fg-1);">
            No cameras yet
          </div>
          <div style="font-size: 13px; color: var(--hs-fg-3);">
            Add one to <code>config.yml</code> and reload.
          </div>
        </div>

        <section
          id="camera-grid"
          style="display: grid; grid-template-columns: repeat(auto-fill, minmax(340px, 1fr)); gap: 16px;"
        >
          <article
            :for={cam <- @cameras}
            id={"camera-tile-#{cam.id}"}
            class="hs-card"
            style={tile_style(@live_events[cam.id] == true)}
          >
            <div style="position: relative; aspect-ratio: 16 / 9; background: var(--hs-bg-sunken);">
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
                style="position: absolute; inset: 0; width: 100%; height: 100%; object-fit: cover;"
              ></video>
              <div style="position: absolute; top: 10px; left: 10px; display: inline-flex; align-items: center; gap: 6px; padding: 3px 10px 3px 8px; border-radius: 999px; background: rgba(11, 15, 20, 0.78); font-size: 11px; font-weight: 600; letter-spacing: 0.02em; font-family: var(--hs-font-sans);">
                <span
                  id={"camera-status-#{cam.id}"}
                  data-status={status(@statuses, cam.id)}
                  style={"display: inline-flex; align-items: center; gap: 6px; color: #{meta(status(@statuses, cam.id)).color};"}
                >
                  <span style={
                    "width: 7px; height: 7px; border-radius: 50%; background: currentColor;" <>
                      if(meta(status(@statuses, cam.id))[:pulse],
                        do: " animation: cairn-pulse 1.4s ease-in-out infinite;",
                        else: ""
                      )
                  }></span>
                  {meta(status(@statuses, cam.id)).label}
                </span>
              </div>
              <div
                :if={@live_events[cam.id]}
                id={"camera-live-event-#{cam.id}"}
                class="live-event-marker"
                style="position: absolute; top: 10px; right: 10px; display: inline-flex; align-items: center; gap: 6px; padding: 3px 10px; border-radius: 999px; background: var(--hs-red-500); color: white; font-size: 11px; font-weight: 700; letter-spacing: 0.06em; pointer-events: none;"
              >
                <span style="width: 7px; height: 7px; border-radius: 50%; background: white; animation: cairn-rec 1.1s ease-in-out infinite;"></span>
                REC
              </div>
              <div
                :if={meta(status(@statuses, cam.id))[:msg]}
                style="position: absolute; inset: 0; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 8px; background: rgba(11, 15, 20, 0.92); pointer-events: none; padding: 16px; text-align: center;"
              >
                <span
                  class="ms"
                  style={"font-size: 34px; color: #{meta(status(@statuses, cam.id)).color};"}
                >
                  {meta(status(@statuses, cam.id))[:icon]}
                </span>
                <div style="font-size: 13px; color: var(--hs-fg-2); max-width: 260px; line-height: 1.4;">
                  {meta(status(@statuses, cam.id))[:msg]}
                </div>
              </div>
            </div>
            <div style="display: flex; align-items: center; gap: 10px; padding: 10px 12px;">
              <h2 style="margin: 0; font-family: var(--hs-font-mono); font-size: 13px; font-weight: 500; color: var(--hs-fg-1);">
                {cam.id}
              </h2>
              <div style="flex: 1;"></div>
              <div
                id={"camera-transport-#{cam.id}"}
                data-transport={transport(@transports, cam.id)}
                style="display: flex; gap: 2px; background: var(--hs-bg-sunken); border-radius: 999px; padding: 2px;"
                title="Stream transport"
              >
                <button
                  phx-click="toggle-transport"
                  phx-value-camera={cam.id}
                  phx-value-transport="mse"
                  style={seg_style(transport(@transports, cam.id) == :mse)}
                >
                  Standard
                </button>
                <button
                  phx-click="toggle-transport"
                  phx-value-camera={cam.id}
                  phx-value-transport="webrtc"
                  style={seg_style(transport(@transports, cam.id) == :webrtc)}
                >
                  Low latency
                </button>
              </div>
            </div>
          </article>
        </section>
      </main>
    </Layouts.app>
    """
  end
end
