defmodule Cairn.DetectionAggregator do
  @moduledoc """
  Owns the event lifecycle, one active event per camera.

  Receives decoded `Cairn.Observation`s from `Cairn.PluginPort` /
  `Cairn.PluginGroupPort`, filters by per-label `min_score`, assigns stable
  object ids (`Cairn.Tracker`), and:

    * no active event + detection -> starts a `Cairn.EventExtractor` and
      broadcasts `{:event_started, event}` on `"events"`
    * detection during an event -> accumulates time-indexed labels, resets
      the post-window timer, broadcasts `{:event_updated, event}`
    * `post_window` seconds of quiet -> finalizes; `max_event` seconds ->
      finalizes and lets the next detection open a fresh event

  Event times come from the observation, not from the clock: `started_at`,
  `labels[].t` and `trigger.t` derive from `observation.observed_at`, which a
  v1 plugin captured next to the frame. Wall-clock time is still what closes
  an event — `ended_at`, the post-window and max-event timers — because
  quiet produces no observations to measure quiet with.

  Subscribes to `Cairn.StreamEpochs`: a new epoch for a camera resets that
  camera's tracker, so object ids are never inherited across an outage.

  Active events are checkpointed to `Cairn.EventCheckpoint` (ETS owned
  elsewhere): on restart the aggregator re-attaches to live extractors and
  finalizes orphans.
  """

  use GenServer

  require Logger

  alias Cairn.{CameraControl, Event, EventCheckpoint, Observation, StreamEpochs, Tracker}

  @max_label_entries 5_000

  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Called by the plugin ports with a decoded, config-tagged observation."
  @spec detections(GenServer.server(), Cairn.Config.Camera.t(), map(), Observation.t()) :: :ok
  def detections(server \\ __MODULE__, camera, windows, %Observation{} = observation) do
    GenServer.cast(server, {:detections, camera, windows, observation})
  end

  # -- server -----------------------------------------------------------------

  @impl true
  def init(opts) do
    StreamEpochs.subscribe()

    state = %{
      cameras: %{},
      # last announced epoch per camera, kept whether or not that camera has
      # tracker state yet: the first epoch of a camera's life is minted at
      # ffmpeg spawn, long before any detection creates `cameras[camera_id]`.
      epochs: %{},
      start_extractor: Keyword.get(opts, :start_extractor, &Cairn.EventExtractor.start/2),
      finalize_extractor: Keyword.get(opts, :finalize_extractor, &Cairn.EventExtractor.finalize/2)
    }

    {:ok, restore_from_checkpoint(state)}
  end

  @impl true
  def handle_cast({:detections, camera, windows, observation}, state) do
    control = CameraControl.get(camera.id)

    cond do
      not control.detection_enabled ->
        # detection disabled at runtime: drop the batch. An in-flight event is
        # left to finalize naturally on its post-window timer.
        {:noreply, state}

      stale?(state, camera.id, observation) ->
        {:noreply, state}

      true ->
        {:noreply, process_detections(state, camera, windows, observation, control)}
    end
  end

  # Belt and braces: the ports already refuse observations from an epoch that
  # is no longer current, and this closes the window where a port's line and
  # the epoch broadcast cross. Compared against the same `current_epoch` the
  # epoch broadcast maintains — including for a camera with no tracker state
  # yet, whose announced epoch is remembered in `epochs`.
  #
  # An observation with no epoch (v0 before the first ffmpeg spawn) is
  # accepted, as is one for a camera whose epoch is not known here yet: that
  # first observation's epoch is adopted in `process_detections/5`.
  defp stale?(_state, _camera_id, %Observation{epoch: nil}), do: false

  defp stale?(state, camera_id, %Observation{epoch: epoch}) do
    case current_epoch(state, camera_id) do
      nil ->
        false

      ^epoch ->
        false

      _other ->
        # Rare by construction, so it is counted rather than logged per line:
        # a steady rate here means a port is forwarding across a boundary.
        :telemetry.execute([:cairn, :aggregator, :stale_observation], %{count: 1}, %{
          camera_id: camera_id
        })

        Logger.debug("camera #{camera_id}: dropped observation from stale epoch #{epoch}")
        true
    end
  end

  # The camera's own state is authoritative once it exists; before that, the
  # last announced epoch is all there is.
  defp current_epoch(state, camera_id) do
    case state.cameras do
      %{^camera_id => cam} -> cam.current_epoch
      _absent -> state.epochs[camera_id]
    end
  end

  defp process_detections(state, camera, windows, observation, control) do
    cam = cam_state(state, camera.id)
    {tracker, tagged} = Tracker.track(cam.tracker, observation.objects)
    cam = %{cam | tracker: tracker, current_epoch: cam.current_epoch || observation.epoch}

    # Predicted ("tracked") objects keep the tracker warm but are not
    # evidence: they can neither open an event nor hold one open.
    min_score = effective_min_score(camera, control)

    passing =
      Enum.filter(tagged, &(Observation.detected?(&1) and passes_min_score?(&1, min_score)))

    cam =
      cond do
        passing == [] -> cam
        # recording disabled: evaluate detections but don't open a new event
        cam.event == nil and not control.recording_enabled -> cam
        cam.event == nil -> start_event(state, camera, windows, observation, passing, cam)
        true -> update_event(cam, windows, observation, passing)
      end

    put_cam(state, camera.id, cam)
  end

  # A runtime min_score override replaces the camera's configured thresholds
  # (applied as the default for every label); nil means "use config".
  defp effective_min_score(camera, %{min_score: nil}), do: camera.min_score
  defp effective_min_score(_camera, %{min_score: override}), do: %{"default" => override}

  @impl true
  def handle_info({:post_window, camera_id, event_id, token}, state) do
    # the token guards against a stale timer message that was already in
    # the mailbox when a detection cancelled + rescheduled the window
    if token == get_in(state.cameras, [camera_id, :post_token]) do
      {:noreply, maybe_finalize(state, camera_id, event_id, :post_window)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:max_event, camera_id, event_id, token}, state) do
    if token == get_in(state.cameras, [camera_id, :max_token]) do
      {:noreply, maybe_finalize(state, camera_id, event_id, :max_event)}
    else
      {:noreply, state}
    end
  end

  # A new epoch is a new continuous decode: the camera may have moved during
  # the outage, so no track may span the boundary — otherwise a box that
  # happens to overlap the last one inherits its object id. `Tracker.reset/1`
  # (not `new/0`) keeps the id counter advancing, so an event whose labels
  # straddle the boundary never reports one id for two objects. An in-flight
  # event keeps running and finalizes on its own timers.
  #
  # Detection casts already in flight when this arrives are processed *after*
  # the reset: they come from the plugin ports, not from `Cairn.StreamEpochs`,
  # and the BEAM only orders messages per sender pair, so a batch from before
  # the boundary would otherwise seed the fresh tracker. The epoch now travels
  # with the batch — tagged at the producer, compared in `stale?/3` against the
  # `current_epoch` stored here — so such a batch is dropped instead.
  def handle_info({:stream_epoch, camera_id, epoch, reason}, state) do
    state = remember_epoch(state, camera_id, epoch, reason)

    case state.cameras do
      %{^camera_id => %{current_epoch: ^epoch}} ->
        # One mint can be announced twice by design: `Cairn.StreamEpochs`
        # broadcasts from the caller when its server is unreachable, and a
        # call that exited with :timeout may still be served afterwards. The
        # epoch is the same either way, so a repeat means no boundary was
        # crossed — resetting again would cut tracks mid-stream. The repeat
        # is caught even when the first announcement arrived before this
        # camera had any tracker state: `epochs` remembered it, and the state
        # created by the first detection starts out carrying it.
        {:noreply, state}

      %{^camera_id => cam} ->
        cam = %{cam | tracker: Tracker.reset(cam.tracker), current_epoch: epoch}
        {:noreply, put_cam(state, camera_id, cam)}

      _ ->
        # no tracker to cut. Allocating full camera state here would retain a
        # tracker for every camera that never emits detections, deleted ones
        # included; the epoch alone (one string) is cheap enough to keep.
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    case Enum.find(state.cameras, fn {_id, cam} -> cam.extractor == pid end) do
      {camera_id, %{event: %Event{} = event} = cam} when reason != :normal ->
        Logger.warning("event #{event.id}: extractor crashed (#{inspect(reason)})")
        EventCheckpoint.delete(camera_id)
        Event.broadcast(:event_ended, %{event | status: :partial, ended_at: now()})
        {:noreply, put_cam(state, camera_id, clear_event(cam))}

      {camera_id, cam} ->
        {:noreply, put_cam(state, camera_id, clear_event(cam))}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- lifecycle --------------------------------------------------------------

  defp start_event(state, camera, windows, observation, dets, cam) do
    observed_at = observation.observed_at

    event = %Event{
      id: Ecto.UUID.generate(),
      camera_id: camera.id,
      started_at: observed_at,
      status: :active,
      labels: label_entries([], dets, observed_at, observed_at),
      max_scores: max_scores(%{}, dets),
      trigger: best_trigger(nil, dets, 0.0)
    }

    event = %{event | max_score: event.max_scores |> Map.values() |> Enum.max(fn -> nil end)}

    case state.start_extractor.(camera, event) do
      {:ok, pid} ->
        Process.monitor(pid)
        EventCheckpoint.put(camera.id, event)
        Event.broadcast(:event_started, event)

        {post_ref, post_token} = schedule(:post_window, camera.id, event.id, windows.post)
        {max_ref, max_token} = schedule(:max_event, camera.id, event.id, windows.max)

        %{
          cam
          | event: event,
            extractor: pid,
            post_ref: post_ref,
            post_token: post_token,
            max_ref: max_ref,
            max_token: max_token
        }

      {:error, reason} ->
        Logger.error("camera #{camera.id}: could not start extractor: #{inspect(reason)}")
        cam
    end
  end

  defp update_event(%{event: event} = cam, windows, observation, dets) do
    max_scores = max_scores(event.max_scores, dets)
    observed_at = observation.observed_at

    event = %{
      event
      | labels: label_entries(event.labels, dets, event.started_at, observed_at),
        max_scores: max_scores,
        max_score: max_scores |> Map.values() |> Enum.max(fn -> nil end),
        trigger:
          best_trigger(
            event.trigger,
            dets,
            DateTime.diff(observed_at, event.started_at, :millisecond) / 1000
          )
    }

    if cam.post_ref, do: Process.cancel_timer(cam.post_ref)
    EventCheckpoint.put(event.camera_id, event)
    Event.broadcast(:event_updated, event)

    {post_ref, post_token} = schedule(:post_window, event.camera_id, event.id, windows.post)
    %{cam | event: event, post_ref: post_ref, post_token: post_token}
  end

  defp maybe_finalize(state, camera_id, event_id, cause) do
    case state.cameras[camera_id] do
      %{event: %Event{id: ^event_id} = event} = cam ->
        Logger.info("event #{event.id} (#{camera_id}): finalizing (#{cause})")
        event = %{event | ended_at: now(), status: :finalized}
        state.finalize_extractor.(cam.extractor, event)
        EventCheckpoint.delete(camera_id)
        Event.broadcast(:event_ended, event)
        put_cam(state, camera_id, clear_event(cam))

      _ ->
        state
    end
  end

  # -- restore ----------------------------------------------------------------

  defp restore_from_checkpoint(state) do
    Enum.reduce(EventCheckpoint.all(), state, fn {camera_id, event}, state ->
      case Cairn.Registry.whereis(camera_id, {:extractor, event.id}) do
        nil ->
          # extractor gone: the index row (if any) stays active on disk and
          # boot-time reconciliation will mark it partial
          EventCheckpoint.delete(camera_id)
          Event.broadcast(:event_ended, %{event | status: :partial, ended_at: now()})
          state

        pid ->
          Process.monitor(pid)
          cam = %{new_cam() | event: event, extractor: pid}
          # windows are unknown here; use the global defaults conservatively
          windows = Cairn.Config.windows(config(), %Cairn.Config.Camera{id: camera_id})
          {post_ref, post_token} = schedule(:post_window, camera_id, event.id, windows.post)
          {max_ref, max_token} = schedule(:max_event, camera_id, event.id, windows.max)

          cam = %{
            cam
            | post_ref: post_ref,
              post_token: post_token,
              max_ref: max_ref,
              max_token: max_token
          }

          put_cam(state, camera_id, cam)
      end
    end)
  end

  defp config do
    Cairn.Config.Server.get()
  rescue
    _ -> %Cairn.Config{}
  catch
    :exit, _ -> %Cairn.Config{}
  end

  # -- helpers ----------------------------------------------------------------

  defp passes_min_score?(det, min_score) do
    threshold = Map.get(min_score, det.label) || Map.get(min_score, "default", 0.5)
    det.score >= threshold
  end

  defp label_entries(entries, dets, started_at, observed_at) do
    t = DateTime.diff(observed_at, started_at, :millisecond) / 1000

    new =
      for det <- dets do
        %{
          t: Float.round(max(t, 0.0), 1),
          label: det.label,
          score: det.score,
          object_id: det.object_id
        }
      end

    Enum.take(entries ++ new, @max_label_entries)
  end

  defp max_scores(acc, dets) do
    Enum.reduce(dets, acc, fn det, acc ->
      Map.update(acc, det.label, det.score, &max(&1, det.score))
    end)
  end

  # The event's single highest-scoring detection, kept with its bbox and time
  # offset — the frame the snapshot is cut from (see Cairn.Snapshot). Keeps the
  # incumbent on ties so the earliest such detection wins.
  defp best_trigger(current, dets, t) do
    Enum.reduce(dets, current, fn det, best ->
      if is_nil(best) or det.score > best.score do
        %{t: Float.round(max(t, 0.0), 2), label: det.label, score: det.score, bbox: det.bbox}
      else
        best
      end
    end)
  end

  defp schedule(kind, camera_id, event_id, seconds) do
    token = make_ref()
    tref = Process.send_after(self(), {kind, camera_id, event_id, token}, seconds * 1_000)
    {tref, token}
  end

  # `:camera_stopped` announces the end of a stream — nothing will ever decode
  # under that epoch. Dropping the entry instead of storing it is what keeps
  # `epochs` from growing one row per camera ever removed.
  defp remember_epoch(state, camera_id, _epoch, :camera_stopped),
    do: %{state | epochs: Map.delete(state.epochs, camera_id)}

  defp remember_epoch(state, camera_id, epoch, _reason),
    do: %{state | epochs: Map.put(state.epochs, camera_id, epoch)}

  # State created here starts on the camera's last announced epoch, so a
  # repeat of that announcement is recognised as one and cuts nothing.
  defp cam_state(state, camera_id),
    do: state.cameras[camera_id] || new_cam(state.epochs[camera_id])

  defp new_cam(current_epoch \\ nil) do
    %{
      event: nil,
      extractor: nil,
      tracker: Tracker.new(),
      current_epoch: current_epoch,
      post_ref: nil,
      post_token: nil,
      max_ref: nil,
      max_token: nil
    }
  end

  defp clear_event(cam) do
    if cam.post_ref, do: Process.cancel_timer(cam.post_ref)
    if cam.max_ref, do: Process.cancel_timer(cam.max_ref)

    %{
      cam
      | event: nil,
        extractor: nil,
        post_ref: nil,
        post_token: nil,
        max_ref: nil,
        max_token: nil
    }
  end

  defp put_cam(state, camera_id, cam) do
    %{state | cameras: Map.put(state.cameras, camera_id, cam)}
  end

  defp now, do: DateTime.utc_now()
end
