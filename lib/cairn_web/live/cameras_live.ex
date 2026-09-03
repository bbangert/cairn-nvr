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

  # On the new page `camera_id` is not an identity: it holds whatever the
  # operator has typed into the id field, so comparing it would call a `?tab=`
  # patch a different form and discard the typed values. There is only ever
  # one new form, so the mode is the whole of the question. On edit the id is
  # the row's and fixed, and a patch to another camera must re-initialize.
  defp same_form?(socket, nil, mode), do: socket.assigns[:mode] == mode

  defp same_form?(socket, camera, mode),
    do: socket.assigns[:mode] == mode and socket.assigns[:camera_id] == camera.id

  # `?tab=` defaults to `scan` in the contract, but discovery is phase 5: until
  # it lands a missing tab shows the form, which is the only tab that works.
  defp tab(%{"tab" => "scan"}), do: :scan
  defp tab(_params), do: :manual

  # A tab patch re-runs `handle_params`; re-initializing there would throw away
  # what the operator has typed.
  defp init_form(socket, camera, mode) do
    if same_form?(socket, camera, mode) do
      socket
    else
      socket
      |> assign(
        mode: mode,
        camera_id: (camera && camera.id) || "",
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
        restart_predicted?: false,
        probe: %{main: blank_probe(:idle), sub: blank_probe(:absent)},
        probe_gen: 0,
        plugins: plugin_names(),
        trackers: Config.tracker_names(),
        known_labels: Cairn.Events.known_labels()
      )
      |> reinit_form(camera)
    end
  end

  # The half of the form's state that a fresh read of the row replaces: the
  # params, what they were when they arrived (the `dirty` baseline), the
  # errors and candidate that were judged against the previous ones, and the
  # probe — its chips describe URLs composed from params that are gone, so
  # both rows go back to unprobed and the generation drops an answer still in
  # flight.
  #
  # The password input is `phx-update="ignore"` and so keeps whatever was
  # typed into it through every patch; only a new id makes LiveView replace
  # the node. Bumping the generation here is what empties it — on a fresh
  # form, on a successful save (`saved/2` re-initializes), and on a pristine
  # refresh from another session's write — so a consumed password cannot ride
  # along on the next, unrelated save.
  defp reinit_form(socket, camera) do
    params = CameraForm.to_params(camera)

    assign(socket,
      saved: camera,
      password_gen: (socket.assigns[:password_gen] || 0) + 1,
      initial_params: params,
      rows: CameraForm.rows(params),
      form: to_form(params, as: :camera),
      candidate: nil,
      field_errors: %{},
      form_errors: [],
      dirty: MapSet.new(),
      restart_predicted?: false,
      probe_gen: (socket.assigns[:probe_gen] || 0) + 1,
      probe: blank_probes(CameraForm.urls(params, camera)),
      stale_notice: false
    )
  end

  # Whether there is a sub stream to remove: the "Remove sub stream" checkbox
  # renders only for a row that has one, because a blank field means "keep"
  # and there is nothing to keep otherwise.
  defp saved_substream?(saved),
    do: is_map(saved) and is_binary(saved.settings["substream_url"])

  # The sub row is rendered only when there is a sub stream to probe, which
  # `:absent` is how the markup is told.
  defp blank_probes(urls) do
    %{main: blank_probe(:idle), sub: blank_probe(if(urls.sub, do: :idle, else: :absent))}
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

  # A click while a probe is running is ignored rather than restarting it: the
  # in-flight one is opening the same URLs — a change to the URL fields resets
  # the rows on its own — so a second would only hold a second ffprobe open
  # and orphan the first's answer under the bumped generation.
  def handle_event("probe", _params, socket) do
    urls = CameraForm.urls(socket.assigns.form.params, socket.assigns.saved)

    if probing?(socket) do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(probe_gen: socket.assigns.probe_gen + 1)
       |> probe_stream(:main, urls.main)
       |> probe_stream(:sub, urls.sub)}
    end
  end

  # The submitted id is read past, not trusted: this button deletes the camera
  # whose page it is on, and the hidden field it posts (a design-contract name)
  # is as forgeable as any other. A hand-sent `remove` can only delete the row
  # the operator could have deleted by clicking.
  def handle_event("remove", _params, socket) do
    id = socket.assigns.camera_id

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

  # Another session deleted the row first, so there is nothing to remove and
  # nothing to render — the same exit as `refresh_row/2`'s.
  def handle_async(:remove, {:ok, {:error, {:write, :not_found}}}, socket),
    do: {:noreply, removed_elsewhere(socket)}

  def handle_async(:remove, {:ok, result}, socket) do
    {:noreply, assign(socket, saving?: false, save_result: done(result(result)))}
  end

  def handle_async(:remove, {:exit, reason}, socket) do
    {:noreply, assign(socket, saving?: false, save_result: done(exit_result(reason)))}
  end

  # A probe answers about the URL it was opened on, and it takes seconds: by
  # the time it lands the operator may have typed a different host, user or
  # password, and the chips would then describe a stream that is not the one
  # on screen. A result from an older generation is dropped rather than
  # rendered — including the exit of the probe `reset_probe/3` cancelled,
  # which arrives here like any other answer.
  def handle_async({:probe, which, gen}, result, socket) do
    if gen == socket.assigns.probe_gen,
      do: {:noreply, put_probe(socket, which, probe_outcome(socket, result))},
      else: {:noreply, socket}
  end

  defp probe_outcome(socket, {:ok, {:ok, probe}}), do: probe_result(socket, probe)
  defp probe_outcome(_socket, {:ok, {:error, reason}}), do: probe_error(reason)
  defp probe_outcome(_socket, {:exit, reason}), do: probe_error(reason)

  defp finish(socket, id),
    do: assign(socket, applying: MapSet.delete(socket.assigns.applying, id))

  @impl true
  # A save this session ran re-reads in `handle_async` as well; both arrive
  # and both are a full re-read, so the order between them does not matter.
  def handle_info({:config_changed, _diff}, socket) do
    {:noreply,
     socket
     |> refresh_globals()
     |> refresh_choices()
     |> refresh_saved()
     |> load()}
  end

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

  # The same reason, for the two lists read off the config server: a form
  # opened while the server was mid-apply got `[]` from it (`plugin_names/0`
  # catches the exit), and the apply that ends with this message is what makes
  # the real answer available.
  defp refresh_choices(socket) do
    if socket.assigns[:mode],
      do: assign(socket, plugins: plugin_names(), trackers: Config.tracker_names()),
      else: socket
  end

  # A row changed in another session while its edit page is open. Pristine, the
  # form is re-initialized from the fresh row: the operator has typed nothing,
  # and saving the params from before would silently put the old values back.
  # Dirty, the typed input is kept — it is the operator's work — and the notice
  # says what a save will do to the other session's change.
  #
  # Removed in another session, there is nothing to edit and nothing a save
  # could land on (`update/2` answers `:not_found`), so the page leaves —
  # dirty or not, since keeping the typed values on a page whose row is gone
  # only promises a save that cannot happen.
  defp refresh_saved(socket) do
    with "edit" <- socket.assigns[:mode],
         # This session's own save broadcasts too, and it arrives before its
         # `handle_async` has re-read the row: the form is still dirty with
         # exactly the change that caused the message.
         false <- socket.assigns.saving? do
      refresh_row(socket, Cameras.get(socket.assigns.camera_id))
    else
      _not_editing -> socket
    end
  end

  defp refresh_row(socket, nil), do: removed_elsewhere(socket)

  # Most `{:config_changed, _}` messages are about some other camera on the
  # node, and this row is then byte-identical to the one already on screen:
  # re-initializing on one would empty the typed password and clear the
  # probe, and calling it stale would accuse another camera's save of
  # touching this one.
  defp refresh_row(socket, camera) do
    cond do
      row_state(socket.assigns.saved) == row_state(camera) -> socket
      Enum.empty?(socket.assigns.dirty) -> reinit_form(socket, camera)
      true -> assign(socket, stale_notice: true)
    end
  end

  # The row is gone — deleted in another session — so there is nothing to edit
  # and nothing a save could land on. Every caller leaves the page: the
  # broadcast that noticed the deletion, and the write that answered
  # `:not_found` because of it.
  defp removed_elsewhere(socket) do
    socket
    |> put_flash(:error, "#{socket.assigns.camera_id} was removed in another session")
    |> push_navigate(to: ~p"/cameras")
  end

  # `position` is deliberately out: a reorder elsewhere changes nothing this
  # form renders or saves.
  defp row_state(nil), do: nil
  defp row_state(camera), do: Map.take(camera, [:settings, :zones, :enabled])

  # The fields that compose a probed URL, plus the two that change what the
  # probe rows show without changing the URL: `clear_substream` toggles the
  # sub row's visibility and `transcode` toggles the not-H.264 warning. The
  # rest of the form changes on every keystroke and would invalidate a probe
  # that is still describing the right stream.
  @probe_fields ~w(rtsp_url substream_url username password clear_substream transcode)

  defp probe_fields_changed?(previous, params),
    do: Enum.any?(@probe_fields, &(param(params, &1) != param(previous, &1)))

  # The rows are reset because a result already rendered would otherwise go on
  # describing a stream the form no longer names. A probe still in flight is
  # cancelled rather than merely outvoted by the generation, which drops the
  # answer but leaves the ffprobe holding a socket open on a URL nobody asked
  # about for the rest of the timeout. The generation still decides, since a
  # cancelled task's exit arrives at `handle_async/3` like any other answer.
  defp reset_probe(socket, false, _params), do: socket

  defp reset_probe(socket, true, params) do
    socket
    |> cancel_running_probes()
    |> assign(
      probe_gen: socket.assigns.probe_gen + 1,
      probe: blank_probes(CameraForm.urls(params, socket.assigns.saved))
    )
  end

  defp cancel_running_probes(socket) do
    gen = socket.assigns.probe_gen

    Enum.reduce(socket.assigns.probe, socket, fn
      {which, %{state: :running}}, acc -> cancel_async(acc, {:probe, which, gen})
      {_which, _row}, acc -> acc
    end)
  end

  defp param(params, key), do: to_string(Map.get(params, key) || "")

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
    # Against the params still on the socket, so this is read before they are
    # replaced below.
    probe_changed? = probe_fields_changed?(socket.assigns.form.params, params)

    socket =
      socket
      |> assign(
        form: to_form(params, as: :camera),
        rows: rows,
        camera_id: camera_id(socket, params),
        dirty: dirty(socket.assigns.initial_params, params)
      )
      |> reset_probe(probe_changed?, params)

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

  defp refuse(socket, errors) do
    show_errors(socket, prefix(errors, route_id(socket)))
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
         {:ok, config, warnings} <- Config.from_map(candidate) do
      assign(socket,
        field_errors: %{},
        form_errors: [],
        warnings: warnings,
        restart_predicted?: restart_predicted?(config, socket.assigns.camera_id)
      )
    else
      {:error, errors} -> show_errors(socket, errors)
    end
  end

  # The near-Save line, from the resolved values rather than from the set of
  # fields that were touched: typing back the value a camera already inherits
  # from the globals moves a field without moving anything its tree was built
  # from. Both false-answers are the quiet ones — a camera the running config
  # has not got is being added, not restarted, and a server mid-apply cannot
  # be asked (the `get/1` exit `overlay/0` catches).
  defp restart_predicted?(candidate_config, camera_id) do
    Config.Server.would_restart?(
      Config.Server.get(Cameras.server()),
      candidate_config,
      camera_id
    )
  catch
    :exit, _ -> false
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

  # Every refusal lands here, so this is where the candidate is dropped: the
  # save reads it, so a `save` racing the debounced `validate` cannot write
  # what validate just rejected — including a fleet error raised after
  # `candidate_for/2` had already assigned one.
  defp show_errors(socket, errors) do
    {field_errors, unclaimed} = CameraForm.field_errors(errors, route_id(socket))
    # Warnings and the restart prediction come back only for a candidate with
    # zero errors, so they are dropped rather than left stale next to an error
    # that supersedes them — there is no config to predict against and no save
    # to predict for.
    assign(socket,
      candidate: nil,
      field_errors: field_errors,
      form_errors: unclaimed,
      warnings: [],
      restart_predicted?: false
    )
  end

  # "Has the operator typed anything?", and nothing else: `refresh_saved/1`
  # re-initializes a pristine form from another session's write and keeps a
  # dirty one. So every cell counts, Track and Record and Days included — an
  # edit this set cannot see is work the refresh would silently discard. The
  # restart line is no longer read off it (`restart_predicted?/2` compares
  # resolved values instead).
  defp dirty(initial, params) do
    scalar =
      params
      |> Map.drop(["labels"])
      |> Enum.filter(fn {key, value} -> to_string(value) != to_string(initial[key] || "") end)
      |> Enum.map(fn {key, _value} -> key end)

    MapSet.new(scalar ++ changed_cells(initial, params))
  end

  @row_cells ~w(min_score track record retention_days)

  # Each cell paired with its row's label, so a renamed, added or removed row
  # reads as a change to every cell it carries rather than to none.
  defp changed_cells(initial, params) do
    for cell <- @row_cells, cells(initial, cell) != cells(params, cell), do: cell
  end

  defp cells(params, cell) do
    params |> CameraForm.rows() |> Enum.map(&{&1["label"], &1[cell]})
  end

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
      # The row can be gone: another session may have deleted it between this
      # write committing and this answer arriving, and `reinit_form/2` has no
      # row to render. Same exit as `refresh_row/2`'s — there is nothing left
      # to edit.
      case Cameras.get(socket.assigns.camera_id) do
        nil ->
          removed_elsewhere(socket)

        camera ->
          socket
          |> reinit_form(camera)
          |> assign(saving?: false, save_result: done(result(result)))
      end
    end
  end

  defp saved(socket, {:error, errors} = result) when is_list(errors) do
    socket |> show_errors(errors) |> assign(saving?: false, save_result: done(result(result)))
  end

  # The row went away between this write starting and it landing: `update/2`
  # answers `:not_found` and the form has nothing left to render.
  defp saved(socket, {:error, {:write, :not_found}}), do: removed_elsewhere(socket)

  defp saved(socket, result),
    do: assign(socket, saving?: false, save_result: done(result(result)))

  defp applying_result,
    do: %{ok: true, phase: :applying, diff: nil, warnings: [], errors: []}

  defp done(result), do: Map.put(result, :phase, :done)

  # An exit reason is `{exception, stacktrace}`, and an exception raised under
  # the write carries the settings map — password and all — so it goes to the
  # log and never to the page.
  #
  # `unconfirmed` because an exit is not a rollback: `Config.Server.update/3`
  # times the caller out at 30 s while the server may still commit and apply,
  # so the card must not promise that nothing changed.
  defp exit_result(reason) do
    Logger.error("cameras: the write did not finish: #{CameraCards.describe_exit(reason)}")

    "the save did not finish in time — it may still apply; reload the page to see"
    |> error_result()
    |> Map.put(:unconfirmed, true)
  end

  defp probing?(socket),
    do: Enum.any?(socket.assigns.probe, fn {_which, row} -> row.state == :running end)

  defp probe_stream(socket, _which, nil), do: socket

  defp probe_stream(socket, which, url) do
    timeout = Application.get_env(:cairn, :probe_timeout_ms, 15_000)

    socket
    |> put_probe(which, blank_probe(:running))
    # The composed URL carries the credential, so it is probed and never
    # rendered — `#camera-url-readout` shows the masked form instead.
    |> start_async({:probe, which, socket.assigns.probe_gen}, fn ->
      Cairn.Probe.run(url, timeout)
    end)
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

  # Neither the log nor the card sees the reason itself: it can be a decode
  # error holding ffprobe's output, which quotes the credentialed URL. Both
  # get one of the sentences `describe_probe_error/1` allows.
  defp probe_error(reason) do
    message = CameraCards.describe_probe_error(reason)
    Logger.warning("cameras: probe failed: #{message}")
    %{state: :error, chips: [], warning: false, error: message}
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
  # is applying a config (the save holds it through `apply_diff`). The call's
  # exit is caught the way `Cairn.CameraTracker` does it, and a page opened
  # mid-save renders the busy card instead; the `{:config_changed, _}` that
  # ends the apply re-reads.
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
      plugin: plugin_label(camera.settings["plugin"]),
      transcode: camera.settings["transcode"] == true
    }
  end

  # A skipped row's `plugin` is whatever its settings column holds, map
  # included — and a map interpolated into the markup takes the whole list
  # down instead of the one row the operator came here to fix.
  defp plugin_label(plugin) when is_binary(plugin), do: plugin
  defp plugin_label(nil), do: "no detection"
  defp plugin_label(_other), do: "invalid"

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
          <%!-- A disabled camera has no runtime to report and its status was
                pruned when it stopped, so the badge would read "Unknown" and
                invite the operator to fix something that is off on purpose. --%>
          <span
            :if={@mode == "edit" and @saved.enabled}
            id={"camera-status-#{@camera_id}"}
            data-status={CameraCards.status(@statuses, @camera_id)}
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
          :if={@stale_notice}
          id="camera-stale"
          class="hs-card"
          style="padding: 14px 16px; font-size: 13px; color: var(--hs-warning); border-color: var(--hs-warning);"
        >
          This camera was changed in another session — saving will overwrite it; reload to see the change.
        </section>

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
          restart_predicted={@restart_predicted?}
          camera_id={@camera_id}
          password_gen={@password_gen}
          saved_substream={saved_substream?(@saved)}
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
          <%!-- `phx-update="ignore"`: `open` is state only the client has
                (`showModal()` sets it), and a patch that re-rendered this
                subtree would drop it and close the dialog under the
                operator. Nothing inside changes while the page is open — the
                title, the hidden id and the two buttons are all fixed by the
                camera being edited. --%>
          <dialog
            id="camera-remove-confirm"
            class="hs-modal"
            phx-hook="Dialog"
            phx-update="ignore"
            aria-labelledby="camera-remove-title"
            style="padding: 16px; border-radius: 10px; border: 1px solid var(--hs-border); background: var(--hs-bg-raised); color: var(--hs-fg-1);"
          >
            <form phx-submit="remove" style="display: flex; flex-direction: column; gap: 12px;">
              <input type="hidden" name={hidden_id_name()} value={@camera_id} />
              <h2
                id="camera-remove-title"
                style="margin: 0; font-size: 15px; font-weight: 600; color: var(--hs-fg-1);"
              >
                Remove {@camera_id}?
              </h2>
              <div style="font-size: 13px; color: var(--hs-fg-2); max-width: 380px;">
                Recording stops now. Its events, clips and tracks stay under the id {@camera_id} until retention removes them. Home Assistant keeps the device until it next reads the camera list.
              </div>
              <div style="display: flex; gap: 8px;">
                <%!-- No `disabled={@saving?}`: an ignored subtree never takes
                      a patched attribute, so it would freeze at whatever the
                      first render said. `phx-disable-with` disables this
                      button on the click itself, and `handle_event("remove",
                      …)` drops a second submit regardless. --%>
                <button type="submit" class="hs-btn hs-btn--danger" phx-disable-with="Removing…">
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
                :if={cam.loaded == "loaded"}
                id={"camera-status-#{cam.id}"}
                data-status={status(@statuses, cam)}
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
                aria-label={if cam.enabled, do: "Disable #{cam.id}", else: "Enable #{cam.id}"}
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

  # A `<dialog>` is only a dialog through `showModal()` — focus trap, inert
  # background, Esc to close — and no attribute the server renders can call
  # it. The event is dispatched at the element instead and the `Dialog` hook
  # (assets/js/hooks/dialog.js) makes the call; an inline script is out, the
  # CSP forbids it.
  defp show_modal(id), do: JS.dispatch("cairn:show-modal", to: "##{id}")
  defp hide_modal(id), do: JS.dispatch("cairn:hide-modal", to: "##{id}")
end
