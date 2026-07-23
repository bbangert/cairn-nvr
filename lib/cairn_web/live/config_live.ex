defmodule CairnWeb.ConfigLive do
  @moduledoc """
  Read-only config page with reload workflow (functional scaffold —
  visual design from the Claude Design handoff).

  Reload button (`phx-click="reload"`) calls `Cairn.Config.Server.reload/0`
  and renders the returned diff/warnings, or the errors with a
  "previous config still active" notice. RTSP passwords are masked before
  render. Probe results per camera come from `Cairn.CameraStatus` (Phase 8).
  """

  use CairnWeb, :live_view

  alias Cairn.Config

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
      last_load: Config.Server.last_load(),
      statuses: Cairn.CameraStatus.all()
    )
  end

  @credential_params ~w(password pass pwd token secret user username)

  @doc false
  # masks userinfo (rtsp://user:secret@host) AND credential-looking query
  # params (Reolink-style http://host/flv?user=x&password=y)
  def mask_url(url) do
    masked = String.replace(url, ~r/(\/\/[^:\/@]+:)[^@\/]+@/, "\\1*****@")

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
        if String.downcase(key) in @credential_params, do: "#{key}=*****", else: pair

      _ ->
        pair
    end
  end

  defp probe(statuses, camera_id) do
    statuses |> Map.get(camera_id, %{}) |> Map.get(:probe)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <h1>Config</h1>
      <p>
        Read-only. Edit <code>config.yml</code>
        and <button id="config-reload" phx-click="reload">Reload</button>
      </p>

      <section :if={@reload_result} id="reload-result" data-ok={to_string(@reload_result.ok)}>
        <div :if={@reload_result.ok}>
          <p>Reloaded.</p>
          <p :if={@reload_result.diff.added != []}>
            Added: {Enum.join(@reload_result.diff.added, ", ")}
          </p>
          <p :if={@reload_result.diff.removed != []}>
            Removed: {Enum.join(@reload_result.diff.removed, ", ")}
          </p>
          <p :if={@reload_result.diff.changed != []}>
            Restarted: {Enum.join(@reload_result.diff.changed, ", ")}
          </p>
          <ul :if={@reload_result.warnings != []}>
            <li :for={w <- @reload_result.warnings} class="warning">{w}</li>
          </ul>
        </div>
        <div :if={!@reload_result.ok}>
          <p><strong>Reload failed — previous config still active.</strong></p>
          <ul>
            <li :for={e <- @reload_result.errors} class="error">{e}</li>
          </ul>
        </div>
      </section>

      <section :if={@last_load.warnings != [] or @last_load.errors != []} id="config-health">
        <h2>Config health</h2>
        <ul>
          <li :for={e <- @last_load.errors} class="error">{e}</li>
          <li :for={w <- @last_load.warnings} class="warning">{w}</li>
        </ul>
      </section>

      <section id="config-globals">
        <h2>Globals</h2>
        <dl>
          <dt>data_dir</dt>
          <dd><code>{@config.data_dir}</code></dd>
          <dt>Windows (pre/post/max)</dt>
          <dd>
            {@config.pre_window_seconds}s / {@config.post_window_seconds}s / {@config.max_event_seconds}s
          </dd>
          <dt>Retention</dt>
          <dd>
            {@config.retention_days}d
            <span :for={{label, days} <- @config.retention_per_label}>· {label}: {days}d</span>
          </dd>
          <dt>UDP</dt>
          <dd>base {@config.udp_base_port}, range {@config.udp_port_range}</dd>
          <dt>Stall threshold</dt>
          <dd>{@config.stall_seconds}s</dd>
          <dt>Free-space floor</dt>
          <dd>{@config.free_space_min_mb} MB</dd>
        </dl>
      </section>

      <section id="config-cameras">
        <h2>Cameras</h2>
        <article :for={cam <- @config.cameras} id={"config-camera-#{cam.id}"}>
          <h3>{cam.id}</h3>
          <dl>
            <dt>Source</dt>
            <dd><code>{mask_url(cam.rtsp_url)}</code></dd>
            <dt>Plugin</dt>
            <dd><code>{if cam.plugin, do: Enum.join(cam.plugin, " "), else: "none"}</code></dd>
            <dt>min_score</dt>
            <dd>
              <span :for={{label, score} <- cam.min_score}>{label}: {score}</span>
            </dd>
            <dt>Transcode</dt>
            <dd>{cam.transcode}</dd>
            <dt :if={probe(@statuses, cam.id)}>Probe</dt>
            <dd :if={probe(@statuses, cam.id)} id={"probe-#{cam.id}"}>
              {inspect(probe(@statuses, cam.id))}
            </dd>
          </dl>
        </article>
      </section>
    </Layouts.app>
    """
  end
end
