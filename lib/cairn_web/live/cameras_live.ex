defmodule CairnWeb.CamerasLive do
  @moduledoc """
  The camera list and the add/edit form, in `hs-*` scaffold styling until the
  design export lands. The form's markup and its params<->settings
  translation are `CairnWeb.CameraForm`; what is here is the socket half —
  the candidate fleet each keystroke is validated against, and the writes.

  A row is a database row overlaid with what the running config made of it:
  `loaded` (the fleet has it), `skipped` (the loader refused this row — its
  errors render on the row, which stays editable), `disabled`, or `unloaded`
  (the running config has no such camera and nothing refused it by name — the
  load failed as a whole, and `#cameras-load-errors` says why). Every state
  the operator can act on is therefore visible without reading a log.

  Every write runs in `start_async` — the toggle, a save, a remove: each walks
  `apply_diff`, which stops and starts camera trees and takes seconds.
  """

  use CairnWeb, :live_view

  require Logger

  alias Cairn.Cameras
  alias Cairn.Config
  alias CairnWeb.CameraCards
  alias CairnWeb.CameraForm

  @row_style "padding: 14px 16px; display: flex; flex-direction: column; gap: 10px;"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Config.Server.subscribe()
      Cairn.CameraStatus.subscribe()
    end

    {:ok,
     socket
     |> assign(save_result: nil, applying: MapSet.new(), statuses: Cairn.CameraStatus.all())
     |> load()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params), do: assign(socket, page_title: "Cameras")

  defp apply_action(socket, :new, params) do
    socket
    |> assign(page_title: "Add camera", tab: tab(params))
    |> init_form(nil, "new")
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case Cameras.get(id) do
      nil ->
        socket |> put_flash(:error, "Unknown camera") |> push_navigate(to: ~p"/cameras")

      camera ->
        socket
        |> assign(page_title: "Edit #{camera.id}", tab: :manual)
        |> init_form(camera, "edit")
    end
  end

  # `?tab=` defaults to `scan` in the contract, but discovery is phase 5: until
  # it lands a missing tab shows the form, which is the only tab that works.
  defp tab(%{"tab" => "scan"}), do: :scan
  defp tab(_params), do: :manual

  # A tab patch re-runs `handle_params`; re-initializing there would throw away
  # what the operator has typed.
  defp init_form(socket, camera, mode) do
    if socket.assigns[:mode] == mode and socket.assigns[:camera_id] == (camera && camera.id) do
      socket
    else
      params = CameraForm.to_params(camera)

      socket
      |> assign(
        mode: mode,
        saved: camera,
        camera_id: (camera && camera.id) || "",
        initial_params: params,
        rows: CameraForm.rows(params),
        form: to_form(params, as: :camera),
        candidate: nil,
        # The non-camera half of the fleet `candidate/2` validates. Cached
        # because a keystroke would otherwise re-read and re-parse config.yml
        # on every 300 ms debounce tick, which on a board is the most
        # expensive thing this page does; `{:config_changed, _}` refreshes it.
        globals: Config.raw_map(Config.default_path()),
        field_errors: %{},
        form_errors: [],
        warnings: [],
        dirty: MapSet.new(),
        saving?: false,
        save_result: nil,
        probe: %{main: blank_probe(:idle), sub: blank_probe(:absent)},
        plugins: plugin_names(),
        trackers: Config.tracker_names(),
        known_labels: Cairn.Events.known_labels()
      )
    end
  end

  defp blank_probe(state), do: %{state: state, chips: [], warning: false, error: nil}

  defp plugin_names do
    Cameras.server() |> Config.Server.get() |> Map.get(:plugin_groups) |> Enum.map(& &1.name)
  catch
    :exit, _ -> []
  end

  # The in-flight guards are the server's own: `disabled` in the markup stops
  # the first click's own button, but not a second event from a stale DOM, a
  # double submit or a hand-sent one. A write already applying wins.
  @impl true
  def handle_event("toggle-enabled", %{"id" => id}, socket) do
    row = Enum.find(socket.assigns.cameras, &(&1.id == id))

    if row && not applying?(socket, id),
      do: {:noreply, apply_async(socket, id, fn -> Cameras.set_enabled(id, !row.enabled) end)},
      else: {:noreply, socket}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    if applying?(socket, id),
      do: {:noreply, socket},
      else: {:noreply, apply_async(socket, id, fn -> Cameras.delete(id) end)}
  end

  def handle_event("validate", %{"camera" => params}, socket) do
    {:noreply, validate(socket, params)}
  end

  def handle_event("save", %{"camera" => params}, socket) do
    socket = validate(socket, params)

    # A nil candidate is a form the validator refused, and it already renders
    # why; `saving?` drops a second submit while the first is still applying.
    if socket.assigns.candidate && not socket.assigns.saving? do
      {:noreply, save(socket, socket.assigns.candidate)}
    else
      {:noreply, socket}
    end
  end

  # Re-validating is the point: a row added or removed changes the duplicate,
  # excluded and tier rules, and without this the errors from before the click
  # stay on screen until the next keystroke.
  def handle_event("add-label-row", _params, socket) do
    {:noreply, revalidate(socket, socket.assigns.rows ++ [CameraForm.blank_row("")])}
  end

  # Index 0 is the `default` block and has no Remove button; the guard is here
  # because a hand-sent event is not bound by the markup.
  def handle_event("remove-label-row", %{"index" => index}, socket) do
    case Integer.parse(index) do
      {n, ""} when n > 0 ->
        {:noreply, revalidate(socket, List.delete_at(socket.assigns.rows, n))}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_event("probe", _params, socket) do
    urls = CameraForm.urls(socket.assigns.form.params, socket.assigns.saved)

    {:noreply,
     socket
     |> probe_stream(:main, urls.main)
     |> probe_stream(:sub, urls.sub)}
  end

  def handle_event("remove", %{"id" => id}, socket) do
    if socket.assigns.saving? do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(saving?: true, save_result: applying_result())
       |> start_async(:remove, fn -> Cameras.delete(id) end)}
    end
  end

  defp applying?(socket, id), do: MapSet.member?(socket.assigns.applying, id)

  defp apply_async(socket, id, fun) do
    socket
    |> assign(applying: MapSet.put(socket.assigns.applying, id))
    |> start_async({:apply, id}, fun)
  end

  @impl true
  def handle_async({:apply, id}, {:ok, result}, socket) do
    {:noreply, socket |> finish(id) |> assign(save_result: result(result)) |> load()}
  end

  def handle_async({:apply, id}, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> finish(id)
     |> assign(save_result: exit_result(reason))
     |> load()}
  end

  def handle_async(:save, {:ok, result}, socket), do: {:noreply, saved(socket, result)}

  def handle_async(:save, {:exit, reason}, socket) do
    {:noreply, assign(socket, saving?: false, save_result: done(exit_result(reason)))}
  end

  def handle_async(:remove, {:ok, {:ok, _diff, _warnings}}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "removed #{socket.assigns.camera_id}")
     |> push_navigate(to: ~p"/cameras")}
  end

  def handle_async(:remove, {:ok, result}, socket) do
    {:noreply, assign(socket, saving?: false, save_result: done(result(result)))}
  end

  def handle_async(:remove, {:exit, reason}, socket) do
    {:noreply, assign(socket, saving?: false, save_result: done(exit_result(reason)))}
  end

  def handle_async({:probe, which}, {:ok, {:ok, probe}}, socket) do
    {:noreply, put_probe(socket, which, probe_result(socket, probe))}
  end

  def handle_async({:probe, which}, {:ok, {:error, reason}}, socket) do
    {:noreply, put_probe(socket, which, probe_error(reason))}
  end

  def handle_async({:probe, which}, {:exit, reason}, socket) do
    {:noreply, put_probe(socket, which, probe_error(reason))}
  end

  defp finish(socket, id),
    do: assign(socket, applying: MapSet.delete(socket.assigns.applying, id))

  @impl true
  # A save this session ran re-reads in `handle_async` as well; both arrive
  # and both are a full re-read, so the order between them does not matter.
  def handle_info({:config_changed, _diff}, socket),
    do: {:noreply, socket |> refresh_globals() |> load()}

  def handle_info({:camera_status, id, info}, socket) do
    {:noreply, assign(socket, statuses: Map.put(socket.assigns.statuses, id, info))}
  end

  # Only while a form is open: a save elsewhere may have rewritten the YAML's
  # non-camera keys, and the cached copy is what validate reads.
  defp refresh_globals(socket) do
    if socket.assigns[:globals],
      do: assign(socket, globals: Config.raw_map(Config.default_path())),
      else: socket
  end

  defp result({:ok, diff, warnings}),
    do: %{ok: true, diff: diff, warnings: warnings, errors: []}

  defp result({:error, {:write, reason}}),
    do: error_result("the save could not be written: #{CameraCards.describe_write_error(reason)}")

  defp result({:error, errors}) when is_list(errors),
    do: %{ok: false, diff: nil, warnings: [], errors: errors}

  defp error_result(message), do: %{ok: false, diff: nil, warnings: [], errors: [message]}

  defp validate(socket, params) do
    rows = CameraForm.rows(params)
    params = Map.put(params, "labels", CameraForm.index_rows(rows))

    socket =
      assign(socket,
        form: to_form(params, as: :camera),
        rows: rows,
        camera_id: camera_id(socket, params),
        dirty: dirty(socket.assigns.initial_params, params)
      )

    cond do
      blank_id?(socket) -> refuse(socket, ["id is required"])
      taken_id?(socket) -> refuse(socket, ["id has already been taken"])
      true -> candidate_for(socket, params)
    end
  end

  defp candidate_for(socket, params) do
    case CameraForm.to_settings(params, socket.assigns.saved) do
      {:ok, settings} -> socket |> assign(candidate: settings) |> candidate(settings)
      {:error, errors} -> refuse(socket, errors)
    end
  end

  # An id the parser would reject is a form error like any other, but a blank
  # one never reaches the parser: the fleet validator names cameras by id, so
  # the refusal has to come from here to land under the field.
  defp blank_id?(%{assigns: %{mode: "new", camera_id: ""}}), do: true
  defp blank_id?(_socket), do: false

  # A refused form has no candidate: the save reads that, so a `save` event
  # racing the debounced `validate` cannot write what validate just rejected.
  defp refuse(socket, errors) do
    socket
    |> assign(candidate: nil)
    |> show_errors(prefix(errors, route_id(socket)))
  end

  # The id is a primary key, so a collision is a *write* failure — and one the
  # fleet validator cannot see, because the candidate replaces the colliding
  # row rather than joining it. Checked before the candidate is built so the
  # save is refused with the message under the field instead of a rejected
  # insert (whose changeset carries the password).
  defp taken_id?(%{assigns: %{mode: "new"}} = socket) do
    socket.assigns.camera_id != "" and Cameras.get(socket.assigns.camera_id) != nil
  end

  defp taken_id?(_socket), do: false

  defp revalidate(socket, rows) do
    params = Map.put(socket.assigns.form.params, "labels", CameraForm.index_rows(rows))
    validate(socket, params)
  end

  # The id is fixed once the row exists; on `:new` it is whatever is typed.
  defp camera_id(%{assigns: %{mode: "edit"}} = socket, _params), do: socket.assigns.camera_id
  defp camera_id(_socket, params), do: String.trim(params["id"] || "")

  # Errors this module raises itself are given the loader's own `camera <id>: `
  # prefix so they route to a field through the one routing table. A camera
  # with no id yet still needs a name to route under.
  defp route_id(socket) do
    case socket.assigns.camera_id do
      "" -> "unnamed"
      id -> id
    end
  end

  defp prefix(errors, id), do: Enum.map(errors, &"camera #{id}: #{&1}")

  # Disk-touching (`Config.from_map/1` reads profiles and artifacts) but fast,
  # and it is the only way a keystroke can see the cross-camera rules; the
  # inputs debounce at 300 ms. The YAML's own globals come from the cache.
  defp candidate(socket, settings) do
    with {:ok, raw} <- socket.assigns.globals,
         candidate = Map.put(raw, "cameras", fleet(socket, settings)),
         {:ok, _config, warnings} <- Config.from_map(candidate) do
      assign(socket, field_errors: %{}, form_errors: [], warnings: warnings)
    else
      {:error, errors} -> show_errors(socket, errors)
    end
  end

  # The fleet a load would render, with this camera's unsaved settings in
  # place of its row. A *disabled* camera is not in it at all: `ConfigSource`
  # renders enabled rows only, so validating one would invent cross-camera
  # errors (ladder capacity, one model per VM) the save itself cannot hit.
  defp fleet(socket, settings) do
    id = route_id(socket)
    zones = (socket.assigns.saved && socket.assigns.saved.zones) || []
    candidate = Cameras.render_row(%{id: id, settings: settings, zones: zones})
    enabled = Enum.filter(Cameras.list(), & &1.enabled)

    rows =
      Enum.map(enabled, fn camera ->
        if camera.id == id, do: candidate, else: Cameras.render_row(camera)
      end)

    cond do
      Enum.any?(enabled, &(&1.id == id)) -> rows
      match?(%{enabled: false}, socket.assigns.saved) -> rows
      true -> rows ++ [candidate]
    end
  end

  defp show_errors(socket, errors) do
    {field_errors, unclaimed} = CameraForm.field_errors(errors, route_id(socket))
    # Warnings come back only for a candidate with zero errors, so they are
    # dropped rather than left stale next to an error that supersedes them.
    assign(socket, field_errors: field_errors, form_errors: unclaimed, warnings: [])
  end

  # Conservative on the label rows: any cell edit marks `min_score` dirty, so
  # the restart line can appear for a hot-only tier change. The chip is a
  # prediction either way — the badge on the result card is the diff's word.
  defp dirty(initial, params) do
    scalar =
      params
      |> Map.drop(["labels"])
      |> Enum.filter(fn {key, value} -> to_string(value) != to_string(initial[key] || "") end)
      |> Enum.map(fn {key, _value} -> key end)

    rows = if CameraForm.rows(params) == CameraForm.rows(initial), do: [], else: ["min_score"]

    MapSet.new(scalar ++ rows)
  end

  defp restart_dirty?(dirty),
    do: Enum.any?(CameraForm.restart_fields(), &MapSet.member?(dirty, &1))

  defp save(socket, settings) do
    id = socket.assigns.camera_id
    saved = socket.assigns.saved

    write =
      if saved,
        do: fn -> Cameras.update(id, %{"settings" => settings}) end,
        else: fn -> Cameras.create(%{"id" => id, "settings" => settings}) end

    socket
    |> assign(saving?: true, save_result: applying_result())
    |> start_async(:save, write)
  end

  # Decision 7: a create lands on the list with its card, an edit stays put —
  # the operator tuning thresholds saves several times in a row.
  defp saved(socket, {:ok, _diff, _warnings} = result) do
    if socket.assigns.mode == "new" do
      socket
      |> put_flash(:info, "added #{socket.assigns.camera_id}")
      |> push_navigate(to: ~p"/cameras")
    else
      camera = Cameras.get(socket.assigns.camera_id)
      params = CameraForm.to_params(camera)

      socket
      |> assign(
        saving?: false,
        save_result: done(result(result)),
        saved: camera,
        initial_params: params,
        rows: CameraForm.rows(params),
        form: to_form(params, as: :camera),
        field_errors: %{},
        form_errors: [],
        dirty: MapSet.new()
      )
    end
  end

  defp saved(socket, {:error, errors} = result) when is_list(errors) do
    socket |> show_errors(errors) |> assign(saving?: false, save_result: done(result(result)))
  end

  defp saved(socket, result),
    do: assign(socket, saving?: false, save_result: done(result(result)))

  defp applying_result,
    do: %{ok: true, phase: :applying, diff: nil, warnings: [], errors: []}

  defp done(result), do: Map.put(result, :phase, :done)

  # An exit reason is `{exception, stacktrace}`, and an exception raised under
  # the write carries the settings map — password and all — so it goes to the
  # log and never to the page.
  defp exit_result(reason) do
    Logger.error("cameras: the write did not finish: #{inspect(reason)}")
    error_result("the save did not finish — see the log")
  end

  defp probe_stream(socket, _which, nil), do: socket

  defp probe_stream(socket, which, url) do
    timeout = Application.get_env(:cairn, :probe_timeout_ms, 15_000)

    socket
    |> put_probe(which, blank_probe(:running))
    # The composed URL carries the credential, so it is probed and never
    # rendered — `#camera-url-readout` shows the masked form instead.
    |> start_async({:probe, which}, fn -> Cairn.Probe.run(url, timeout) end)
  end

  defp put_probe(socket, which, result),
    do: assign(socket, probe: Map.put(socket.assigns.probe, which, result))

  defp probe_result(socket, probe) do
    transcode? = socket.assigns.form.params["transcode"] in ["true", "on"]

    %{
      state: :ok,
      chips: CameraCards.probe_chips(probe),
      warning: is_binary(probe[:codec]) and probe.codec != "h264" and not transcode?,
      error: nil
    }
  end

  # The reason is logged whole and rendered only as one of the sentences
  # `describe_probe_error/1` allows: it can be a decode error holding
  # ffprobe's output, which quotes the credentialed URL.
  defp probe_error(reason) do
    Logger.warning("cameras: probe failed: #{inspect(reason)}")
    %{state: :error, chips: [], warning: false, error: CameraCards.describe_probe_error(reason)}
  end

  defp zone_summary(0), do: "No zones — presence counts the whole frame"
  defp zone_summary(count), do: "#{zone_label(count)} on this camera"

  defp load(socket) do
    rows = Cameras.list()

    case overlay() do
      {:ok, config, last_load} ->
        assign(socket,
          busy?: false,
          last_load: last_load,
          cameras: Enum.map(rows, &row(&1, config, last_load))
        )

      :busy ->
        assign(socket, busy?: true, last_load: blank_load(), cameras: [])
    end
  end

  defp blank_load, do: %{warnings: [], errors: [], skipped: %{}}

  # `get/1` and `last_load/1` are 5 s calls the server cannot answer while it
  # is applying a config (the save holds it through `apply_diff`), so a page
  # opened mid-save exits rather than renders — the `Cairn.CameraTracker`
  # treatment. The `{:config_changed, _}` that ends the apply re-reads.
  defp overlay do
    server = Cameras.server()
    {:ok, Config.Server.get(server), Config.Server.last_load(server)}
  catch
    :exit, _ -> :busy
  end

  defp row(camera, config, last_load) do
    errors = Map.get(last_load.skipped, camera.id, [])

    %{
      id: camera.id,
      enabled: camera.enabled,
      loaded: loaded(camera, config, last_load),
      errors: errors,
      zones: length(camera.zones),
      plugin: camera.settings["plugin"] || "no detection",
      transcode: camera.settings["transcode"] == true
    }
  end

  defp loaded(%{enabled: false}, _config, _last_load), do: "disabled"

  defp loaded(camera, config, last_load) do
    cond do
      Enum.any?(config.cameras, &(&1.id == camera.id)) -> "loaded"
      Map.has_key?(last_load.skipped, camera.id) -> "skipped"
      # Neither in the running config nor refused by name: the load failed as
      # a whole (a bad `plugins:` group, a capacity fault, a DB fault) and
      # never reached this row. Calling that `skipped` would put a warning
      # border and an empty error list on every row at once and blame each of
      # them for a fleet-level fault; `#cameras-load-errors` carries the real
      # reason.
      true -> "unloaded"
    end
  end

  defp status(statuses, %{loaded: "loaded"} = row), do: CameraCards.status(statuses, row.id)
  # A skipped or unloaded camera has no runtime to report, and a disabled
  # one's status was pruned when it stopped.
  defp status(_statuses, _row), do: :unknown

  # A row that is not running reads as a problem to fix (warning border); a
  # disabled one is quiet, because that is what the operator asked for.
  defp row_style(%{loaded: state}) when state in ["skipped", "unloaded"],
    do: @row_style <> " border-color: var(--hs-warning);"

  defp row_style(%{loaded: "disabled"}), do: @row_style <> " opacity: 0.65;"
  defp row_style(_row), do: @row_style

  defp zone_label(0), do: "whole frame"
  defp zone_label(1), do: "1 zone"
  defp zone_label(n), do: "#{n} zones"

  defp running_count(cameras, statuses),
    do: Enum.count(cameras, &(status(statuses, &1) == :running))

  @impl true
  def render(%{live_action: action} = assigns) when action in [:new, :edit] do
    ~H"""
    <Layouts.app flash={@flash} page={:cameras}>
      <main
        id="camera-editor"
        style="flex: 1; padding: 20px; max-width: 720px; width: 100%; margin: 0 auto; box-sizing: border-box; display: flex; flex-direction: column; gap: 16px;"
      >
        <div style="display: flex; align-items: center; gap: 12px;">
          <h1 style="margin: 0; font-size: 22px; font-weight: 600; letter-spacing: -0.01em; color: var(--hs-fg-1); font-family: var(--hs-font-mono);">
            {@page_title}
          </h1>
          <span
            :if={@mode == "edit"}
            id={"camera-status-#{@camera_id}"}
            class="hs-badge"
            style={"color: #{CameraCards.status_meta(CameraCards.status(@statuses, @camera_id)).color};"}
          >
            <span class="hs-dot"></span>{CameraCards.status_meta(
              CameraCards.status(@statuses, @camera_id)
            ).label}
          </span>
          <div style="flex: 1;"></div>
          <.link navigate={~p"/cameras"} class="hs-btn hs-btn--sm">Back to cameras</.link>
        </div>

        <nav
          :if={@mode == "new"}
          id="camera-new-tabs"
          role="tablist"
          style="display: flex; gap: 8px;"
        >
          <.link
            id="tab-scan"
            patch={~p"/cameras/new?tab=scan"}
            role="tab"
            aria-selected={to_string(@tab == :scan)}
            class="hs-btn hs-btn--sm"
          >
            Find on network
          </.link>
          <.link
            id="tab-manual"
            patch={~p"/cameras/new?tab=manual"}
            role="tab"
            aria-selected={to_string(@tab == :manual)}
            class="hs-btn hs-btn--sm"
          >
            Enter stream URLs
          </.link>
        </nav>

        <CameraCards.save_result :if={@save_result} result={@save_result} />

        <section
          :if={@warnings != []}
          id="camera-warnings"
          class="hs-card"
          style="padding: 14px 16px; display: flex; flex-direction: column; gap: 4px; font-size: 13px; color: var(--hs-warning); border-color: var(--hs-warning);"
        >
          <div :for={warning <- @warnings}>{warning}</div>
        </section>

        <section
          :if={@mode == "new" and @tab == :scan}
          id="onvif-scan"
          data-state="idle"
          class="hs-card"
          style="padding: 16px; display: flex; flex-direction: column; gap: 8px;"
        >
          <div style="font-size: 14px; font-weight: 600; color: var(--hs-fg-1);">
            Find on network
          </div>
          <div style="font-size: 13px; color: var(--hs-fg-2);">
            ONVIF discovery arrives in a later release. Enter the camera's stream URLs for now.
          </div>
        </section>

        <div :if={@mode == "edit"} style="display: flex; flex-direction: column; gap: 16px;">
          <div
            id="camera-url-readout"
            class="hs-card"
            style="padding: 12px 14px; background: var(--hs-bg-sunken); font-family: var(--hs-font-mono); font-size: 12px; color: var(--hs-fg-2); display: flex; flex-direction: column; gap: 4px;"
          >
            <div>{CameraCards.mask_url(@saved.settings["rtsp_url"] || "")}</div>
            <div :if={@saved.settings["substream_url"]}>
              {CameraCards.mask_url(@saved.settings["substream_url"])}
            </div>
          </div>

          <div
            id="camera-zones-summary"
            data-zones={length(@saved.zones)}
            class="hs-card"
            style="padding: 12px 14px; display: flex; align-items: center; gap: 10px; font-size: 13px; color: var(--hs-fg-2);"
          >
            {zone_summary(length(@saved.zones))}
            <div style="flex: 1;"></div>
            <%!-- Disabled, not linked: `/cameras/:id/zones` is phase 4's route,
                  and a link to a route the router has not got is a 404 for the
                  operator. Phase 4 swaps in the `~p` link. --%>
            <button
              type="button"
              class="hs-btn hs-btn--sm"
              disabled
              title="The zone editor arrives with the next release"
            >
              Edit zones
            </button>
          </div>
        </div>

        <%!-- The plugin groups and the fleet validate reads both come from the
              config server, which cannot answer mid-apply: editing against a
              half-known config would validate against no plugins at all. --%>
        <section :if={@busy?} id="camera-busy" class="hs-card" style="padding: 16px;">
          <div style="display: flex; align-items: center; gap: 8px; font-size: 14px; color: var(--hs-fg-2);">
            <span class="ms" style="font-size: 19px;">hourglass_top</span>
            Configuration is being applied — this page will refresh
          </div>
        </section>

        <CameraForm.camera_form
          :if={not @busy? and (@mode == "edit" or @tab == :manual)}
          form={@form}
          rows={@rows}
          mode={@mode}
          field_errors={@field_errors}
          form_errors={@form_errors}
          plugins={@plugins}
          trackers={@trackers}
          known_labels={@known_labels}
          probe={@probe}
          saving={@saving?}
          restart_dirty={restart_dirty?(@dirty)}
          camera_id={@camera_id}
        />

        <div :if={@mode == "edit"} style="display: flex; flex-direction: column; gap: 10px;">
          <button
            id="camera-remove"
            type="button"
            class="hs-btn hs-btn--sm"
            style="align-self: flex-start; color: var(--hs-danger);"
            phx-click={show_modal("camera-remove-confirm")}
          >
            Remove camera
          </button>
          <dialog
            id="camera-remove-confirm"
            class="hs-modal"
            style="padding: 16px; border-radius: 10px; border: 1px solid var(--hs-border); background: var(--hs-bg-raised); color: var(--hs-fg-1);"
          >
            <form phx-submit="remove" style="display: flex; flex-direction: column; gap: 12px;">
              <input type="hidden" name={hidden_id_name()} value={@camera_id} />
              <div style="font-size: 13px; color: var(--hs-fg-2); max-width: 380px;">
                Recording stops now. Its events, clips and tracks stay under the id {@camera_id} until retention removes them. Home Assistant keeps the device until it next reads the camera list.
              </div>
              <div style="display: flex; gap: 8px;">
                <button
                  type="submit"
                  class="hs-btn hs-btn--danger"
                  phx-disable-with="Removing…"
                  disabled={@saving?}
                >
                  Remove {@camera_id}
                </button>
                <button
                  type="button"
                  class="hs-btn hs-btn--sm"
                  phx-click={hide_modal("camera-remove-confirm")}
                >
                  Cancel
                </button>
              </div>
            </form>
          </dialog>
        </div>
      </main>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page={:cameras}>
      <main
        id="cameras"
        style="flex: 1; padding: 20px; max-width: 980px; width: 100%; margin: 0 auto; box-sizing: border-box; display: flex; flex-direction: column; gap: 16px;"
      >
        <div style="display: flex; align-items: center; gap: 12px;">
          <div>
            <h1 style="margin: 0; font-size: 22px; font-weight: 600; letter-spacing: -0.01em; color: var(--hs-fg-1);">
              Cameras
            </h1>
            <div style="font-size: 13px; color: var(--hs-fg-3); margin-top: 3px;">
              {length(@cameras)} cameras · {running_count(@cameras, @statuses)} running
            </div>
          </div>
          <div style="flex: 1;"></div>
          <.link id="cameras-add" navigate={~p"/cameras/new"} class="hs-btn hs-btn--primary">
            <span class="ms" style="font-size: 18px;">add</span>Add camera
          </.link>
        </div>

        <CameraCards.save_result :if={@save_result} result={@save_result} />

        <%!-- Fleet-level: the load these rows are overlaid with failed as a
              whole, so no row can carry the reason. --%>
        <section
          :if={@last_load.errors != []}
          id="cameras-load-errors"
          class="hs-card"
          style="padding: 14px 16px; display: flex; flex-direction: column; gap: 6px; border-color: var(--hs-danger);"
        >
          <div style="font-size: 14px; font-weight: 600; color: var(--hs-danger);">
            The last config load failed — the cameras below are not running
          </div>
          <div
            :for={error <- @last_load.errors}
            style="font-size: 13px; color: var(--hs-danger); font-family: var(--hs-font-mono);"
          >
            {error}
          </div>
          <div style="font-size: 13px; color: var(--hs-fg-2);">
            <.link navigate={~p"/config"} class="hs-btn hs-btn--sm">Open the config page</.link>
          </div>
        </section>

        <section :if={@busy?} id="cameras-busy" class="hs-card" style="padding: 16px;">
          <div style="display: flex; align-items: center; gap: 8px; font-size: 14px; color: var(--hs-fg-2);">
            <span class="ms" style="font-size: 19px;">hourglass_top</span>
            Configuration is being applied — this page will refresh
          </div>
        </section>

        <div
          :if={!@busy? and @cameras == []}
          id="cameras-empty"
          class="hs-card"
          style="padding: 40px 16px; display: flex; flex-direction: column; align-items: center; gap: 8px; text-align: center;"
        >
          <span class="ms" style="font-size: 46px; color: var(--hs-fg-4);">videocam</span>
          <div style="font-size: 15px; font-weight: 600; color: var(--hs-fg-1);">No cameras yet</div>
          <div style="font-size: 13px; color: var(--hs-fg-3);">
            Find one on your network or enter its stream URLs
          </div>
          <.link
            id="empty-state-add"
            navigate={~p"/cameras/new"}
            class="hs-btn hs-btn--primary"
            style="margin-top: 6px;"
          >
            Add camera
          </.link>
        </div>

        <%!-- A list, not a stream: a node runs 1–9 cameras and every row is
              re-derived from the config on each change anyway. --%>
        <ul
          :if={!@busy? and @cameras != []}
          id="cameras-list"
          style="list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 10px;"
        >
          <li
            :for={cam <- @cameras}
            id={"camera-row-#{cam.id}"}
            data-status={status(@statuses, cam)}
            data-loaded={cam.loaded}
            data-zones={cam.zones}
            data-busy={MapSet.member?(@applying, cam.id) && "true"}
            class="hs-card"
            style={row_style(cam)}
          >
            <div style="display: flex; align-items: center; gap: 10px; flex-wrap: wrap;">
              <span style="font-family: var(--hs-font-mono); font-size: 13px; font-weight: 500; color: var(--hs-fg-1);">
                {cam.id}
              </span>
              <span
                :if={cam.loaded not in ["skipped", "unloaded"]}
                id={"camera-status-#{cam.id}"}
                class="hs-badge"
                style={"color: #{CameraCards.status_meta(status(@statuses, cam)).color};"}
              >
                <span class="hs-dot"></span>{CameraCards.status_meta(status(@statuses, cam)).label}
              </span>
              <span style="font-size: 12px; color: var(--hs-fg-3);">{cam.plugin}</span>
              <span style="font-size: 12px; color: var(--hs-fg-3);">{zone_label(cam.zones)}</span>
              <span :if={cam.transcode} class="hs-badge hs-badge--accent">
                <span class="hs-dot"></span>transcode
              </span>
              <span
                :if={CameraCards.not_h264?(@statuses, cam.id, cam.transcode)}
                class="hs-badge hs-badge--warning"
                title="Switch the camera to H.264 or enable transcode"
              >
                <span class="hs-dot"></span>not H.264
              </span>
              <span
                :if={CameraCards.transcode_unavailable?(@statuses, cam.id)}
                class="hs-badge hs-badge--danger"
              >
                <span class="hs-dot"></span>transcode unavailable
              </span>
            </div>

            <div style="display: flex; gap: 6px; flex-wrap: wrap;">
              <span
                :for={chip <- CameraCards.probe_chips(CameraCards.probe(@statuses, cam.id))}
                id={"probe-#{cam.id}-#{chip}"}
                class="tnum"
                style="display: inline-flex; align-items: center; gap: 5px; padding: 3px 9px; border-radius: 6px; font-size: 12px; background: var(--hs-bg-sunken); color: var(--hs-fg-2); font-family: var(--hs-font-mono);"
              >
                {chip}
              </span>
              <span
                :if={CameraCards.probe_chips(CameraCards.probe(@statuses, cam.id)) == []}
                style="display: inline-flex; align-items: center; gap: 5px; padding: 3px 9px; border-radius: 6px; font-size: 12px; background: var(--hs-bg-sunken); color: var(--hs-warning); font-family: var(--hs-font-mono);"
              >
                not probed yet
              </span>
            </div>

            <div
              :if={cam.errors != []}
              style="display: flex; flex-direction: column; gap: 4px; font-size: 13px; color: var(--hs-warning); font-family: var(--hs-font-mono);"
            >
              <div :for={e <- cam.errors}>{e}</div>
            </div>

            <div style="display: flex; align-items: center; gap: 10px;">
              <button
                id={"camera-enabled-#{cam.id}"}
                class="hs-tog"
                role="switch"
                aria-checked={to_string(cam.enabled)}
                disabled={MapSet.member?(@applying, cam.id)}
                phx-click="toggle-enabled"
                phx-value-id={cam.id}
                title="Enabling or disabling may restart other cameras"
              ></button>
              <div style="flex: 1;"></div>
              <.link navigate={~p"/cameras/#{cam.id}/edit"} class="hs-btn hs-btn--sm">Edit</.link>
              <%!-- Disabled until phase 4 adds the route — see the edit page. --%>
              <button
                type="button"
                class="hs-btn hs-btn--sm"
                disabled
                title="The zone editor arrives with the next release"
              >
                Zones
              </button>
              <button
                class="hs-btn hs-btn--sm"
                disabled={MapSet.member?(@applying, cam.id)}
                phx-click="delete"
                phx-value-id={cam.id}
                data-confirm={"Remove #{cam.id}? Recording stops now. Its events, clips and tracks stay under the id until retention removes them."}
              >
                Remove
              </button>
            </div>
          </li>
        </ul>
      </main>
    </Layouts.app>
    """
  end

  # The remove form's field is named `id` (fixed by the design contract). A
  # literal `name="id"` on an input is a HEEx warning — it would override the
  # element's DOM id — so the name arrives as a value the engine does not
  # inspect. Inlining the string back breaks the build.
  defp hidden_id_name, do: "id"

  # The stock show/hide JS helpers: the dialog is opened by making it visible
  # rather than by `showModal()`, which no server-rendered event can call.
  defp show_modal(id), do: CairnWeb.CoreComponents.show("##{id}")
  defp hide_modal(id), do: CairnWeb.CoreComponents.hide("##{id}")
end
