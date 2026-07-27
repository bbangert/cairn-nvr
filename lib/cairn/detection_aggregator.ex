defmodule Cairn.DetectionAggregator do
  @moduledoc """
  Owns the event lifecycle, one active event per camera.

  Receives decoded detection batches from `Cairn.PluginPort`, filters by
  per-label `min_score`, assigns stable object ids (`Cairn.Tracker`), and:

    * no active event + detection -> starts a `Cairn.EventExtractor` and
      broadcasts `{:event_started, event}` on `"events"`
    * detection during an event -> accumulates time-indexed labels, resets
      the post-window timer, broadcasts `{:event_updated, event}`
    * `post_window` seconds of quiet -> finalizes; `max_event` seconds ->
      finalizes and lets the next detection open a fresh event

  Subscribes to `Cairn.StreamEpochs`: a new epoch for a camera resets that
  camera's tracker, so object ids are never inherited across an outage.

  Active events are checkpointed to `Cairn.EventCheckpoint` (ETS owned
  elsewhere): on restart the aggregator re-attaches to live extractors and
  finalizes orphans.
  """

  use GenServer

  require Logger

  alias Cairn.{CameraControl, Event, EventCheckpoint, StreamEpochs, Tracker}

  @max_label_entries 5_000

  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Called by `Cairn.PluginPort` with a decoded, config-tagged batch."
  @spec detections(GenServer.server(), Cairn.Config.Camera.t(), map(), number(), [map()]) :: :ok
  def detections(server \\ __MODULE__, camera, windows, pts, dets) do
    GenServer.cast(server, {:detections, camera, windows, pts, dets})
  end

  # -- server -----------------------------------------------------------------

  @impl true
  def init(opts) do
    StreamEpochs.subscribe()

    state = %{
      cameras: %{},
      start_extractor: Keyword.get(opts, :start_extractor, &Cairn.EventExtractor.start/2),
      finalize_extractor: Keyword.get(opts, :finalize_extractor, &Cairn.EventExtractor.finalize/2)
    }

    {:ok, restore_from_checkpoint(state)}
  end

  @impl true
  def handle_cast({:detections, camera, windows, pts, dets}, state) do
    control = CameraControl.get(camera.id)

    if control.detection_enabled do
      {:noreply, process_detections(state, camera, windows, pts, dets, control)}
    else
      # detection disabled at runtime: drop the batch. An in-flight event is
      # left to finalize naturally on its post-window timer.
      {:noreply, state}
    end
  end

  defp process_detections(state, camera, windows, pts, dets, control) do
    cam = cam_state(state, camera.id)
    {tracker, tagged} = Tracker.track(cam.tracker, dets)
    cam = %{cam | tracker: tracker}

    passing = Enum.filter(tagged, &passes_min_score?(&1, effective_min_score(camera, control)))

    cam =
      cond do
        passing == [] -> cam
        # recording disabled: evaluate detections but don't open a new event
        cam.event == nil and not control.recording_enabled -> cam
        cam.event == nil -> start_event(state, camera, windows, pts, passing, cam)
        true -> update_event(cam, windows, passing)
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
  # Known residual race: detection casts already in flight when this arrives
  # are processed *after* the reset. They come from the plugin ports, not from
  # `Cairn.StreamEpochs`, and the BEAM only orders messages per sender pair, so
  # a batch from before the boundary can seed the fresh tracker. Closing it
  # needs the epoch to travel with the batch (tagged at the producer, stale
  # batches dropped here), which is protocol v1 Phase 2; `current_epoch` is
  # stored as the anchor that comparison will read.
  def handle_info({:stream_epoch, camera_id, epoch, _reason}, state) do
    case state.cameras do
      %{^camera_id => %{current_epoch: ^epoch}} ->
        # One mint can be announced twice by design: `Cairn.StreamEpochs`
        # broadcasts from the caller when its server is unreachable, and a
        # call that exited with :timeout may still be served afterwards. The
        # epoch is the same either way, so a repeat means no boundary was
        # crossed — resetting again would cut tracks mid-stream.
        {:noreply, state}

      %{^camera_id => cam} ->
        cam = %{cam | tracker: Tracker.reset(cam.tracker), current_epoch: epoch}
        {:noreply, put_cam(state, camera_id, cam)}

      _ ->
        # no tracker to cut. Allocating state here would retain an entry for
        # every camera that never emits detections, deleted ones included.
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

  defp start_event(state, camera, windows, _pts, dets, cam) do
    event = %Event{
      id: Ecto.UUID.generate(),
      camera_id: camera.id,
      started_at: now(),
      status: :active,
      labels: label_entries([], dets, now()),
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

  defp update_event(%{event: event} = cam, windows, dets) do
    max_scores = max_scores(event.max_scores, dets)

    event = %{
      event
      | labels: label_entries(event.labels, dets, event.started_at),
        max_scores: max_scores,
        max_score: max_scores |> Map.values() |> Enum.max(fn -> nil end),
        trigger:
          best_trigger(
            event.trigger,
            dets,
            DateTime.diff(now(), event.started_at, :millisecond) / 1000
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

  defp label_entries(entries, dets, started_at) do
    t = DateTime.diff(now(), started_at, :millisecond) / 1000

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

  defp cam_state(state, camera_id), do: state.cameras[camera_id] || new_cam()

  defp new_cam do
    %{
      event: nil,
      extractor: nil,
      tracker: Tracker.new(),
      current_epoch: nil,
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
