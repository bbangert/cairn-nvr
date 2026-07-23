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
    if connected?(socket), do: Cairn.CameraStatus.subscribe()

    {:ok,
     assign(socket,
       page_title: "Dashboard",
       cameras: Cairn.Config.Server.get().cameras,
       statuses: Cairn.CameraStatus.all()
     )}
  end

  @impl true
  def handle_info({:camera_status, camera_id, info}, socket) do
    {:noreply, update(socket, :statuses, &Map.put(&1, camera_id, info))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
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
          </header>
          <video
            id={"camera-video-#{cam.id}"}
            phx-hook="MsePlayer"
            phx-update="ignore"
            data-camera-id={cam.id}
            data-hls-url={~p"/hls/#{cam.id}/index.m3u8"}
            muted
            autoplay
            playsinline
            class="mt-2 w-full bg-black"
          ></video>
        </article>
      </section>
    </Layouts.app>
    """
  end

  defp status(statuses, camera_id) do
    statuses |> Map.get(camera_id, %{}) |> Map.get(:status, :unknown)
  end
end
