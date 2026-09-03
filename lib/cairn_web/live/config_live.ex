defmodule CairnWeb.ConfigLive do
  @moduledoc """
  Globals page with reload/re-import workflows, styled per the Claude
  Design handoff. Contract preserved: `phx-click="reload"` →
  `Cairn.Config.Server.reload/1`. `phx-click="reimport"` replaces the whole
  camera fleet from `config.yml` (`Cairn.ConfigSource.reimport/1`) — not
  read-only, though it is the only camera write this page makes; every other
  camera edit happens on `/cameras`, which this page only links to.
  """

  use CairnWeb, :live_view

  require Logger

  alias Cairn.Cameras
  alias Cairn.Config
  alias Cairn.ConfigSource
  alias CairnWeb.CameraCards

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Config",
       reload_result: nil,
       reimporting: false,
       busy?: false,
       config: nil,
       config_path: Config.default_path(),
       last_load: nil,
       import_marker: nil,
       reimport_confirm: nil
     )
     |> load()}
  end

  @impl true
  def handle_event("reload", _params, socket) do
    result =
      case Config.Server.reload(Cameras.server()) do
        {:ok, diff, warnings} ->
          %{ok: true, diff: diff, warnings: warnings, errors: [], kind: :reload}

        {:error, errors} ->
          %{ok: false, diff: nil, warnings: [], errors: errors, kind: :reload}
      end

    {:noreply, socket |> assign(reload_result: result) |> load()}
  end

  def handle_event("reimport", _params, socket) do
    path = socket.assigns.config_path

    {:noreply,
     socket
     |> assign(reimporting: true)
     |> start_async(:reimport, fn -> ConfigSource.reimport(path) end)}
  end

  @impl true
  def handle_async(:reimport, {:ok, result}, socket) do
    {:noreply,
     socket
     |> assign(reimporting: false, reload_result: reimport_result(result))
     |> load()}
  end

  # The exit reason can carry the exception that raised — and with it the
  # settings map — so it goes to the log, never the card.
  def handle_async(:reimport, {:exit, reason}, socket) do
    Logger.error("config: the re-import did not finish: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(
       reimporting: false,
       reload_result: error_result("the re-import did not finish — see the log")
     )
     |> load()}
  end

  # Public (not private) only so a test can drive the `{:write, reason}`
  # mapping directly with a constructed reason — the reachable path is a
  # `write_fun` raise inside `Cairn.ConfigSource.reimport/1`'s nested
  # transaction, which is not practical to provoke deterministically through
  # the LiveView. Not called from outside this module.
  @doc false
  @spec reimport_result(Cairn.Cameras.write_result()) :: map()
  def reimport_result({:ok, diff, warnings}),
    do: %{ok: true, diff: diff, warnings: warnings, errors: [], kind: :reimport}

  def reimport_result({:error, {:write, {:yaml, errors}}}),
    do: %{ok: false, diff: nil, warnings: [], errors: errors, kind: :reimport}

  def reimport_result({:error, {:write, reason}}),
    do: error_result(CameraCards.describe_write_error(reason))

  def reimport_result({:error, errors}) when is_list(errors),
    do: %{ok: false, diff: nil, warnings: [], errors: errors, kind: :reimport}

  defp error_result(message),
    do: %{ok: false, diff: nil, warnings: [], errors: [message], kind: :reimport}

  # Server calls, not the reimport task: `get/1` and `last_load/1` are 5 s
  # calls the server cannot answer while it is applying a config (the save
  # holds it through `apply_diff`) — the `Cairn.CamerasLive` treatment,
  # rendered here as a short busy line rather than a crashed mount/event.
  # Everything computed here runs once per `load/1` call, not per render —
  # `@reimport_confirm` in particular used to be recomputed (a YAML re-parse
  # and a DB count) on every `data-confirm` render.
  defp load(socket) do
    server = Cameras.server()

    case overlay(server) do
      {:ok, config, last_load} ->
        path = socket.assigns.config_path

        assign(socket,
          busy?: false,
          config: config,
          last_load: last_load,
          import_marker: ConfigSource.import_marker(),
          reimport_confirm: reimport_confirm(path)
        )

      :busy ->
        assign(socket, busy?: true)
    end
  end

  defp overlay(server) do
    {:ok, Config.Server.get(server), Config.Server.last_load(server)}
  catch
    :exit, _ -> :busy
  end

  defp reimport_confirm(path) do
    "Replace all #{length(Cameras.list())} saved cameras with the #{config_camera_count(path)} " <>
      "in config.yml? Zones drawn in the UI are lost."
  end

  # -- view helpers -----------------------------------------------------------

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

  defp fmt_import_date(%{"imported_at" => iso}) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> CairnWeb.EventsLive.fmt_time(dt)
      {:error, _reason} -> iso
    end
  end

  defp reimportable?(last_load), do: Enum.any?(last_load.warnings, &(&1 =~ ~r/changed since/))

  defp config_camera_count(path) do
    case Config.raw_map(path) do
      {:ok, %{"cameras" => cameras}} when is_list(cameras) -> length(cameras)
      _other -> 0
    end
  end

  defp health_visible?(last_load, marker),
    do: last_load.warnings != [] or last_load.errors != [] or not is_nil(marker)

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
              Node settings, read from <span style="font-family: var(--hs-font-mono); font-size: 12px;">{@config_path}</span>. Cameras are managed on Cameras.
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
            {if @reload_result.kind == :reimport,
              do: "Cameras re-imported from config.yml — changes are live",
              else: "Config reloaded — changes are live"}
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
            <span class="ms" style="font-size: 19px;">error</span>
            {if @reload_result.kind == :reimport,
              do: "We couldn't re-import the cameras",
              else: "We couldn't load the new config"}
          </div>
          <div style="display: flex; flex-direction: column; gap: 4px; font-size: 13px; color: var(--hs-danger); font-family: var(--hs-font-mono);">
            <div :for={e <- @reload_result.errors}>{e}</div>
          </div>
          <div style="font-size: 13px; color: var(--hs-fg-2);">
            Your previous config is still active — nothing changed.
          </div>
        </section>

        <section :if={@busy?} id="config-busy" class="hs-card" style="padding: 16px;">
          <div style="display: flex; align-items: center; gap: 8px; font-size: 14px; color: var(--hs-fg-2);">
            <span class="ms" style="font-size: 19px;">hourglass_top</span>
            Configuration is being applied — this page will refresh
          </div>
        </section>

        <section
          :if={!@busy? and health_visible?(@last_load, @import_marker)}
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
            <div
              :if={@import_marker}
              id="config-import"
              style="display: flex; flex-direction: column; gap: 8px; margin-top: 4px;"
            >
              <div style="display: flex; gap: 7px; color: var(--hs-fg-3);">
                <span class="ms" style="font-size: 16px; flex: none; margin-top: 1px;">history</span>
                Cameras imported from
                <span style="font-family: var(--hs-font-mono);">{@import_marker["path"]}</span>
                on {fmt_import_date(@import_marker)}
              </div>
              <button
                :if={reimportable?(@last_load)}
                id="config-reimport"
                phx-click="reimport"
                disabled={@reimporting}
                data-confirm={@reimport_confirm}
                class="hs-btn hs-btn--secondary"
              >
                <span class="ms" style="font-size: 18px;">sync</span>
                {if @reimporting, do: "Importing…", else: "Import again"}
              </button>
            </div>
          </div>
        </section>

        <section :if={!@busy?} id="config-globals" class="hs-card" style="padding: 16px;">
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
          id="config-cameras-link"
          class="hs-card"
          style="padding: 16px; display: flex; align-items: center; gap: 14px;"
        >
          <span class="ms" style="font-size: 22px; color: var(--hs-fg-3);">videocam</span>
          <div style="flex: 1; font-size: 13px; color: var(--hs-fg-2);">
            Cameras are managed on the Cameras page.
          </div>
          <.link navigate={~p"/cameras"} class="hs-btn hs-btn--secondary">Open Cameras</.link>
        </div>
      </main>
    </Layouts.app>
    """
  end
end
