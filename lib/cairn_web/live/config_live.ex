defmodule CairnWeb.ConfigLive do
  @moduledoc """
  Read-only config page with reload workflow, styled per the Claude Design
  handoff. Contract preserved: `phx-click="reload"` →
  `Cairn.Config.Server.reload/0`; diff/warnings or errors rendered with an
  old-config-retained notice. RTSP/FLV credentials are masked before
  render; probe results come from `Cairn.CameraStatus`.
  """

  use CairnWeb, :live_view

  alias Cairn.Config

  @credential_params ~w(password pass pwd token secret user username)

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Config", reload_result: nil) |> load()}
  end

  @impl true
  def handle_event("reload", _params, socket) do
    result =
      case Config.Server.reload() do
        {:ok, diff, warnings} -> %{ok: true, diff: diff, warnings: warnings, errors: []}
        {:error, errors} -> %{ok: false, diff: nil, warnings: [], errors: errors}
      end

    {:noreply, socket |> assign(reload_result: result) |> load()}
  end

  defp load(socket) do
    assign(socket,
      config: Config.Server.get(),
      config_path: Config.default_path(),
      last_load: Config.Server.last_load(),
      statuses: Cairn.CameraStatus.all()
    )
  end

  @doc false
  # rtsp://user:secret@host/... and ...?password=x&user=y forms
  def mask_url(url) do
    masked = String.replace(url, ~r/(\/\/[^:\/@]+:)[^@\/]+@/, "\\1•••••@")

    case String.split(masked, "?", parts: 2) do
      [base, query] -> base <> "?" <> mask_query(query)
      [base] -> base
    end
  end

  defp mask_query(query) do
    query
    |> String.split("&")
    |> Enum.map_join("&", &mask_query_pair/1)
  end

  defp mask_query_pair(pair) do
    case String.split(pair, "=", parts: 2) do
      [key, _value] ->
        if String.downcase(key) in @credential_params, do: "#{key}=•••••", else: pair

      _ ->
        pair
    end
  end

  # -- view helpers -----------------------------------------------------------

  defp probe(statuses, camera_id) do
    statuses |> Map.get(camera_id, %{}) |> Map.get(:probe)
  end

  defp probe_chips(nil), do: []
  defp probe_chips(%{error: _}), do: []

  defp probe_chips(probe) do
    [
      probe[:codec],
      probe[:width] && probe[:height] && "#{probe.width}×#{probe.height}",
      probe[:fps] && "#{probe.fps} fps",
      probe[:profile]
    ]
    |> Enum.reject(&(&1 in [nil, false]))
  end

  defp globals(config) do
    [
      {"data_dir", config.data_dir},
      {"retention", "#{config.retention_days}d" <> per_label(config.retention_per_label)},
      {"pre-roll", "#{config.pre_window_seconds}s"},
      {"post-roll", "#{config.post_window_seconds}s"},
      {"max event", "#{config.max_event_seconds}s"},
      {"stall threshold", "#{config.stall_seconds}s"},
      {"free-space floor", "#{config.free_space_min_mb} MB"},
      {"remux clips", if(config.remux_clips, do: "on", else: "off")}
    ]
  end

  defp per_label(map) when map_size(map) == 0, do: ""

  defp per_label(map) do
    " · " <> Enum.map_join(map, " · ", fn {label, days} -> "#{label}: #{days}d" end)
  end

  defp camera_rows(config, cam) do
    windows = Config.windows(config, cam)

    [
      {"plugin", plugin_label(cam.plugin)},
      {"min_score", Enum.map_join(cam.min_score, " ", fn {l, s} -> "#{l}: #{s}" end)},
      {"windows", "#{windows.pre}s / #{windows.post}s / #{windows.max}s"},
      {"retention",
       (cam.retention_days && "#{cam.retention_days}d#{per_label(cam.retention_per_label)}") ||
         "inherit"}
    ]
  end

  defp plugin_label({:group, name}), do: name
  defp plugin_label(nil), do: "none"

  defp not_h264?(statuses, cam) do
    case probe(statuses, cam.id) do
      %{codec: codec} when is_binary(codec) and codec != "h264" -> not cam.transcode
      _ -> false
    end
  end

  defp transcode_unavailable?(statuses, camera_id) do
    statuses |> Map.get(camera_id, %{}) |> Map.get(:status) == :transcode_unavailable
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page={:config}>
      <main style="flex: 1; padding: 20px; max-width: 980px; width: 100%; margin: 0 auto; box-sizing: border-box; display: flex; flex-direction: column; gap: 16px;">
        <div style="display: flex; align-items: center; gap: 12px;">
          <div>
            <h1 style="margin: 0; font-size: 22px; font-weight: 600; letter-spacing: -0.01em; color: var(--hs-fg-1);">
              Config
            </h1>
            <div style="font-size: 13px; color: var(--hs-fg-3); margin-top: 3px;">
              Read-only view of
              <span style="font-family: var(--hs-font-mono); font-size: 12px;">{@config_path}</span>
              — edit the file, then reload.
            </div>
          </div>
          <div style="flex: 1;"></div>
          <button id="config-reload" phx-click="reload" class="hs-btn hs-btn--primary">
            <span class="ms" style="font-size: 18px;">refresh</span>Reload config
          </button>
        </div>

        <section
          :if={@reload_result && @reload_result.ok}
          id="reload-result"
          data-ok="true"
          class="hs-card"
          style="padding: 14px 16px; border-color: var(--hs-success); display: flex; flex-direction: column; gap: 10px;"
        >
          <div style="display: flex; align-items: center; gap: 8px; font-size: 14px; font-weight: 600; color: var(--hs-success);">
            <span class="ms" style="font-size: 19px;">check_circle</span>
            Config reloaded — changes are live
          </div>
          <div
            :if={
              @reload_result.diff.added != [] or @reload_result.diff.removed != [] or
                @reload_result.diff.changed != [] or @reload_result.diff.refreshed != []
            }
            style="display: flex; gap: 6px; flex-wrap: wrap;"
          >
            <span :for={id <- @reload_result.diff.added} class="hs-badge hs-badge--success">
              <span class="hs-dot"></span>added {id}
            </span>
            <span :for={id <- @reload_result.diff.removed} class="hs-badge hs-badge--danger">
              <span class="hs-dot"></span>removed {id}
            </span>
            <span :for={id <- @reload_result.diff.changed} class="hs-badge hs-badge--accent">
              <span class="hs-dot"></span>restarted {id}
            </span>
            <%!-- Distinguished from "restarted" because the difference is what the
                  operator will see: a refreshed camera keeps its stream and its
                  live tracks, which is the whole point of tuning thresholds on a
                  running system. --%>
            <span :for={id <- @reload_result.diff.refreshed} class="hs-badge">
              <span class="hs-dot"></span>updated {id}
            </span>
          </div>
          <div
            :if={@reload_result.warnings != []}
            style="display: flex; flex-direction: column; gap: 4px; font-size: 13px; color: var(--hs-warning);"
          >
            <div :for={w <- @reload_result.warnings} style="display: flex; gap: 7px;">
              <span class="ms" style="font-size: 16px; flex: none; margin-top: 1px;">warning</span>{w}
            </div>
          </div>
        </section>

        <section
          :if={@reload_result && !@reload_result.ok}
          id="reload-result"
          data-ok="false"
          class="hs-card"
          style="padding: 14px 16px; border-color: var(--hs-danger); display: flex; flex-direction: column; gap: 10px;"
        >
          <div style="display: flex; align-items: center; gap: 8px; font-size: 14px; font-weight: 600; color: var(--hs-danger);">
            <span class="ms" style="font-size: 19px;">error</span> We couldn't load the new config
          </div>
          <div style="display: flex; flex-direction: column; gap: 4px; font-size: 13px; color: var(--hs-danger); font-family: var(--hs-font-mono);">
            <div :for={e <- @reload_result.errors}>{e}</div>
          </div>
          <div style="font-size: 13px; color: var(--hs-fg-2);">
            Your previous config is still active — nothing changed.
          </div>
        </section>

        <section
          :if={@last_load.warnings != [] or @last_load.errors != []}
          id="config-health"
          class="hs-card"
          style="padding: 16px;"
        >
          <h3 style="margin: 0 0 10px; font-size: 14px; font-weight: 600; color: var(--hs-fg-1); display: flex; align-items: center; gap: 8px;">
            <span class="ms" style="font-size: 18px; color: var(--hs-fg-3);">monitor_heart</span>
            Config health
          </h3>
          <div style="display: flex; flex-direction: column; gap: 5px; font-size: 13px;">
            <div
              :if={@last_load.errors != [] and @config.cameras == []}
              id="config-no-cameras"
              style="display: flex; gap: 7px; color: var(--hs-danger); font-weight: 600;"
            >
              <span class="ms" style="font-size: 16px; flex: none; margin-top: 1px;">videocam_off</span>No cameras are running.
            </div>
            <div
              :for={e <- @last_load.errors}
              style="display: flex; gap: 7px; color: var(--hs-danger);"
            >
              <span class="ms" style="font-size: 16px; flex: none; margin-top: 1px;">error</span>{e}
            </div>
            <div
              :for={w <- @last_load.warnings}
              style="display: flex; gap: 7px; color: var(--hs-warning);"
            >
              <span class="ms" style="font-size: 16px; flex: none; margin-top: 1px;">warning</span>{w}
            </div>
          </div>
        </section>

        <section id="config-globals" class="hs-card" style="padding: 16px;">
          <h3 style="margin: 0 0 12px; font-size: 14px; font-weight: 600; color: var(--hs-fg-1); display: flex; align-items: center; gap: 8px;">
            <span class="ms" style="font-size: 18px; color: var(--hs-fg-3);">public</span>Globals
          </h3>
          <div style="display: grid; grid-template-columns: repeat(auto-fill, minmax(210px, 1fr)); gap: 12px 20px;">
            <div
              :for={{key, value} <- globals(@config)}
              style="display: flex; flex-direction: column; gap: 3px;"
            >
              <span style="font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.06em; color: var(--hs-fg-3);">
                {key}
              </span>
              <span
                class="tnum"
                style="font-family: var(--hs-font-mono); font-size: 13px; color: var(--hs-fg-1);"
              >
                {value}
              </span>
            </div>
          </div>
        </section>

        <div
          id="config-cameras"
          style="display: grid; grid-template-columns: repeat(auto-fill, minmax(400px, 1fr)); gap: 16px;"
        >
          <section
            :for={cam <- @config.cameras}
            id={"config-camera-#{cam.id}"}
            class="hs-card"
            style="padding: 16px; display: flex; flex-direction: column; gap: 10px;"
          >
            <div style="display: flex; align-items: center; gap: 10px; flex-wrap: wrap;">
              <span style="font-family: var(--hs-font-mono); font-size: 14px; font-weight: 500; color: var(--hs-fg-1);">
                {cam.id}
              </span>
              <div style="flex: 1;"></div>
              <span :if={cam.transcode} class="hs-badge hs-badge--accent">
                <span class="hs-dot"></span>transcode
              </span>
              <span
                :if={not_h264?(@statuses, cam)}
                class="hs-badge hs-badge--warning"
                title="Switch the camera to H.264 or enable transcode"
              >
                <span class="hs-dot"></span>not H.264
              </span>
              <span :if={transcode_unavailable?(@statuses, cam.id)} class="hs-badge hs-badge--danger">
                <span class="hs-dot"></span>transcode unavailable
              </span>
            </div>
            <div style="font-family: var(--hs-font-mono); font-size: 12px; color: var(--hs-fg-2); background: var(--hs-bg-sunken); border-radius: 6px; padding: 8px 10px; word-break: break-all;">
              {mask_url(cam.rtsp_url)}
            </div>
            <div style="display: flex; gap: 6px; flex-wrap: wrap;">
              <span
                :for={chip <- probe_chips(probe(@statuses, cam.id))}
                id={"probe-#{cam.id}-#{chip}"}
                class="tnum"
                style="display: inline-flex; align-items: center; gap: 5px; padding: 3px 9px; border-radius: 6px; font-size: 12px; background: var(--hs-bg-sunken); color: var(--hs-fg-2); font-family: var(--hs-font-mono);"
              >
                {chip}
              </span>
              <span
                :if={probe_chips(probe(@statuses, cam.id)) == []}
                style="display: inline-flex; align-items: center; gap: 5px; padding: 3px 9px; border-radius: 6px; font-size: 12px; background: var(--hs-bg-sunken); color: var(--hs-warning); font-family: var(--hs-font-mono);"
              >
                not probed yet
              </span>
            </div>
            <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 8px 20px; font-size: 13px;">
              <div
                :for={{key, value} <- camera_rows(@config, cam)}
                style="display: flex; justify-content: space-between; gap: 10px;"
              >
                <span style="color: var(--hs-fg-3);">{key}</span>
                <span
                  class="tnum"
                  style="font-family: var(--hs-font-mono); font-size: 12px; color: var(--hs-fg-1); text-align: right; word-break: break-all;"
                >
                  {value}
                </span>
              </div>
            </div>
          </section>
        </div>
      </main>
    </Layouts.app>
    """
  end
end
