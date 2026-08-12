defmodule Cairn.PipelineOwner do
  @moduledoc """
  Owns one camera's `Cairn.Pipeline.Camera` — the only process that starts,
  rebuilds or stops it.

  The pipeline is long-lived (D1): reconnects happen inside the sources, and
  epochs are minted in-band by `Cairn.Pipeline.EpochTagger`, so this process
  never sees a session boundary and never rebuilds on one. It starts a fresh
  pipeline for exactly two reasons: the running one died, or the watchdog found
  a wedge that only a fresh one clears. A death backs off first — a
  crash-looping pipeline is a normal long-lived state and must not burn
  supervisor restart intensity.

  ## Status

  This process is the sole author of the lifecycle status
  (`:connecting | :running | :backoff | :stalled`) that `Cairn.CameraStatus`
  serves, with one exception: `Cairn.FFmpegPort` reports the bridge
  connection's own `:connecting`/`:backoff`/`:transcode_unavailable`, which
  live entirely outside the pipeline and nothing here can observe. It
  deliberately does *not* report `:running` — media flowing is the ring's
  answer, given here, so a bridge that connects and never decodes cannot read
  as healthy.

  `:running` is gated on an init segment carrying the camera's *current*
  epoch (`Cairn.StreamEpochs` is the reference; this process no longer mints
  and so no longer knows one first-hand). A superseded session's fragments
  arriving late therefore cannot vouch for the pipeline that replaced it.

  ## Watchdog (D3)

  Per tick, two liveness signals — the ring's last fragment
  (`Cairn.RingBuffer.last_fragment_at/1`) and, for a detecting camera, the age
  of the last buffer at `Cairn.Pipeline.TrackSink` — against
  `config.stall_seconds`:

    * detect branch stale while the ring is healthy: the wedge is downstream
      of the tee, where no reconnect reaches it — rebuild.
    * ring stale on `ingest: rtsp` while the source reports itself connected:
      the same wedge on the recording side — rebuild. A source in backoff or
      lost is a mere outage and gets nothing: the in-element reconnect owns
      it, and a rebuild would only throw away the detect branch's warm state.
    * ring stale on `ingest: ffmpeg`: bounce the bridge first
      (`Cairn.FFmpegPort.bounce/1`, which a port already backing off ignores)
      and escalate to a rebuild only if two further ticks pass with the ring
      still stale and ffmpeg respawned.

  At most one rebuild per stall window, so a camera that comes back slowly is
  not rebuilt twice over the same outage.
  """

  use GenServer

  require Logger

  alias Cairn.{CameraStatus, Config, FFmpegPort, RingBuffer, StreamEpochs}

  @backoff_min_ms 1_000
  @backoff_max_ms 30_000

  # Stale ticks with ffmpeg respawned before the bridge bounce escalates.
  @bridge_escalate_ticks 2

  defstruct camera: nil,
            config: nil,
            opts: [],
            # :init so the first real transition (:connecting) is always emitted
            status: :init,
            pipeline: nil,
            pipeline_ref: nil,
            backoff_ms: nil,
            # reason carried into the *next* pipeline's first epoch
            restart_reason: :started,
            # init_seen gates :running on an init segment carrying the camera's
            # current epoch; got_fragment makes the transition once per pipeline
            init_seen: false,
            got_fragment: false,
            # what the source last told us about the main stream
            source: :unknown,
            # TrackSink's last buffer, monotonic ms, from the relayed stats
            detect_at_ms: nil,
            bridge_stale_ticks: nil,
            rebuilt_at_ms: nil,
            # stands in for the ring's last-fragment time until the first
            # fragment exists — see ring_stale?/1
            pipeline_started_at_ms: nil

  def start_link(opts) do
    cam = Keyword.fetch!(opts, :camera)
    GenServer.start_link(__MODULE__, opts, name: Cairn.Registry.via(cam.id, :pipeline))
  end

  @doc """
  Point a running camera's detect branch at a new config without rebuilding
  the pipeline.

  The `Cairn.Detect.Dispatch` policy is resolved here at pipeline birth, so a
  reload has to reach the running pipeline's detect branch too — otherwise a
  `record:` edit would sit unapplied until the camera's next rebuild. The
  tracker core is the one detect option that does not arrive this way: it
  wires an element rather than feeding one, so a config that names a different
  core restarts the camera instead (`Cairn.Config.Server`'s camera diff).
  """
  @spec refresh(GenServer.server(), Config.Camera.t(), Config.t()) :: :ok
  def refresh(server, %Config.Camera{} = camera, %Config{} = config) do
    GenServer.cast(server, {:refresh, camera, config})
  end

  # -- server -----------------------------------------------------------------

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %__MODULE__{
      camera: Keyword.fetch!(opts, :camera),
      config: Keyword.fetch!(opts, :config),
      backoff_ms: Keyword.get(opts, :backoff_min_ms, @backoff_min_ms),
      opts: opts
    }

    # This process holds no sink to observe fragments on, so the :running
    # transition and the backoff reset ride the ring's own broadcasts.
    Phoenix.PubSub.subscribe(Cairn.PubSub, RingBuffer.topic(state.camera.id))

    # Deferred rather than started here: `init/1` blocks the camera's
    # supervisor, and a pipeline whose elements are slow to set up would hold
    # up the whole tree behind it.
    send(self(), :start)
    schedule_watchdog(state)
    {:ok, state}
  end

  @impl true
  def handle_cast({:refresh, camera, config}, state) do
    state = %{state | camera: camera, config: config}

    # `send/2` and not a call: a refresh must not wait on a pipeline whose
    # detect branch is inside a `push_frame/5`. A pipeline in its backoff window is owed
    # nothing — the next start resolves the policy from `config`.
    if is_pid(state.pipeline) do
      send(state.pipeline, {:policy, camera, Config.policy(config, camera)})
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:start, state) do
    {:noreply, start_pipeline(state, state.restart_reason)}
  end

  # Our own teardown never lands here — `stop_pipeline/1` demonitors with flush
  # first — so any reason, even :normal, is a pipeline that ended without being
  # asked to.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{pipeline_ref: ref} = state) do
    Logger.warning("camera #{state.camera.id}: membrane pipeline died: #{inspect(reason)}")
    {:noreply, enter_backoff(%{state | pipeline: nil, pipeline_ref: nil}, :source_lost)}
  end

  # Relayed from the pipeline's source element. The camera is reachable again,
  # but nothing has decoded yet — :running is the ring's to say.
  def handle_info({:stream_connected, :main, _tracks}, state) do
    {:noreply, set_status(%{state | source: :connected}, :connecting)}
  end

  def handle_info({:stream_backoff, :main, _reason}, state) do
    {:noreply, set_status(%{state | source: :backoff}, :backoff)}
  end

  def handle_info({:stream_lost, :main}, state) do
    {:noreply, %{state | source: :lost}}
  end

  # A sub stream never speaks for the camera's status (phase 3 gives it its own
  # signals); matched explicitly so it cannot fall through as main's.
  def handle_info({tag, :sub, _rest}, state) when tag in [:stream_connected, :stream_backoff] do
    {:noreply, state}
  end

  def handle_info({:stream_lost, :sub}, state), do: {:noreply, state}

  # TrackSink's reply to the watchdog's :detect_stats.
  def handle_info({:stats, %{last_buffer_at_ms: at_ms}}, state) do
    {:noreply, %{state | detect_at_ms: at_ms}}
  end

  # Ring broadcasts. The init segment carries the epoch, fragments do not — so
  # matching it against the camera's current epoch is what ties the
  # fragment-based :running transition to the pipeline that is running *now*.
  def handle_info({:init_segment, %{epoch: epoch}}, state) do
    if StreamEpochs.current(state.camera.id) == {:ok, epoch} do
      {:noreply, %{state | init_seen: true}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:fragment, _frag}, %{init_seen: true, got_fragment: false} = state)
      when state.pipeline != nil do
    state = set_status(state, :running)
    {:noreply, %{state | got_fragment: true, backoff_ms: backoff_min(state)}}
  end

  def handle_info(:watchdog, state) do
    schedule_watchdog(state)
    state = check_liveness(state)

    # Asked after the check, so what the next tick reads is one interval old:
    # the sink answers out of band, and a call would put this process behind
    # whatever the detect branch is currently blocked in.
    if detecting?(state) and is_pid(state.pipeline), do: send(state.pipeline, :detect_stats)

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    # Only a deliberate stop ends the stream: after a crash the restart mints
    # its own epoch, and announcing :camera_stopped in between would make
    # consumers see a stopped -> started flap. Minted *before* the blocking
    # teardown so it is not the first casualty of the supervisor's shutdown
    # budget. Never a guarantee either way — a brutal kill skips terminate/2
    # entirely, so consumers must keep their own timeouts as the backstop.
    # Short timeout: shutdown must not be gated on epoch bookkeeping. A wedged
    # StreamEpochs would otherwise eat the shutdown budget and get us killed
    # before the pipeline is stopped; the degraded path still
    # best-effort-broadcasts.
    if stop_reason?(reason) do
      StreamEpochs.new_epoch(state.camera.id, :camera_stopped, 500)
    end

    # This 500ms bound and flush/1's 500ms grace are additive on the shutdown
    # path; their sum must stay well under the supervisor's 5s budget, which
    # is why neither default is any bigger.
    flush(state)
    stop_pipeline(state)
    :ok
  end

  defp stop_reason?(:normal), do: true
  defp stop_reason?(:shutdown), do: true
  defp stop_reason?({:shutdown, _}), do: true
  defp stop_reason?(_reason), do: false

  # -- pipeline lifecycle -----------------------------------------------------

  defp start_pipeline(state, reason) do
    opts = [
      camera: state.camera,
      owner: self(),
      ingest: state.camera.ingest,
      initial_reason: reason,
      detect: detect_opts(state)
    ]

    module = Keyword.get(state.opts, :pipeline_module, Cairn.Pipeline.Camera)

    state =
      set_status(
        %{
          state
          | init_seen: false,
            got_fragment: false,
            source: :unknown,
            detect_at_ms: nil,
            bridge_stale_ticks: nil,
            pipeline_started_at_ms: now_ms()
        },
        :connecting
      )

    # Here and not (only) on the way down: the registry unregisters the dead
    # pipeline's BridgeSource on its *own* DOWN, unordered relative to anything
    # this process waited on — and a crash reaches this point through
    # `enter_backoff/2`, which never ran a deliberate stop. The fresh
    # BridgeSource hard-matches its register, so every start waits the stale
    # entry out. An rtsp camera registers nothing and this resolves instantly.
    Cairn.Registry.await_unregistered(state.camera.id, :bridge_source)

    case Membrane.Pipeline.start(module, opts) do
      {:ok, _supervisor, pipeline} ->
        %{state | pipeline: pipeline, pipeline_ref: Process.monitor(pipeline)}

      {:error, error} ->
        Logger.error(
          "camera #{state.camera.id}: membrane pipeline failed to start: #{inspect(error)}"
        )

        enter_backoff(state, :source_lost)
    end
  end

  defp enter_backoff(state, reason) do
    state = state |> stop_pipeline() |> set_status(:backoff)
    delay = trunc(state.backoff_ms * (0.5 + :rand.uniform()))
    Process.send_after(self(), :start, delay)

    %{
      state
      | pipeline: nil,
        pipeline_ref: nil,
        backoff_ms: min(state.backoff_ms * 2, backoff_max(state)),
        restart_reason: reason
    }
  end

  defp stop_pipeline(%{pipeline: nil} = state), do: state

  defp stop_pipeline(state) do
    Process.demonitor(state.pipeline_ref, [:flush])
    # force?: a wedged element must not block the rebuild path; the pipeline
    # holds no OS resources, so a hard kill leaks nothing. The stale-registry
    # wait lives in `start_pipeline/2`, where it also covers the crash path.
    Membrane.Pipeline.terminate(state.pipeline, timeout: 5_000, force?: true)
    %{state | pipeline: nil, pipeline_ref: nil}
  end

  # Only on the way out. A rebuild deliberately skips it: the pipeline it is
  # replacing is wedged or dead, so waiting on its tail buys nothing and the
  # camera is off the air meanwhile.
  defp flush(%{pipeline: nil}), do: :ok

  defp flush(state) do
    send(state.pipeline, :flush)
    Process.sleep(Keyword.get(state.opts, :flush_grace_ms, 500))
  end

  # `nil` leaves the pipeline's detect branch unbuilt. `min_score` is the
  # stream's wire floor; the rest of the profile is engine config
  # (`Cairn.Config.native_model_config/1`). `policy:` is resolved here rather
  # than in the detect branch because it is a config round trip, and that
  # branch is the per-frame path.
  defp detect_opts(%{camera: %{plugin: nil}}), do: nil

  # No `sample_fps`: the branch does not thin, and the engine takes the rate
  # from the profile every membrane camera on this node has to agree on
  # (`Cairn.Config.native_model_config/1`).
  #
  # `tracker:` is resolved here rather than carried in the policy because it
  # wires an element rather than feeding one: a reload cannot swap a core under
  # a running branch, which is why a changed core is a camera restart rather
  # than a refresh (`Cairn.Config.Server`).
  defp detect_opts(state) do
    [
      policy: Config.policy(state.config, state.camera),
      tracker: Config.tracker(state.config, state.camera),
      stream_params: %{min_score: state.camera.min_score}
    ]
  end

  defp detecting?(state), do: detect_opts(state) != nil

  # -- watchdog ---------------------------------------------------------------

  defp check_liveness(state) do
    cond do
      detect_stale?(state) and not ring_stale?(state) ->
        rebuild(state, "detect branch stale while the ring is healthy")

      not ring_stale?(state) ->
        %{state | bridge_stale_ticks: nil}

      bridge?(state) ->
        bounce_bridge(state)

      state.source == :connected ->
        rebuild(state, "no fragments while the source reports itself connected")

      true ->
        # An outage, not a wedge: the source's own reconnect owns it, and a
        # rebuild would cost the detect branch's warm state for nothing.
        state
    end
  end

  defp bounce_bridge(state) do
    case {Cairn.Registry.whereis(state.camera.id, :ffmpeg), state.bridge_stale_ticks} do
      # The port is a sibling in the camera's tree and can be restarting; that
      # restart is a bounce of its own.
      {nil, _ticks} ->
        state

      {pid, nil} ->
        Logger.warning("camera #{state.camera.id}: no fragments, bouncing the ffmpeg bridge")
        FFmpegPort.bounce(pid)
        %{state | bridge_stale_ticks: 0}

      {pid, ticks} when ticks >= @bridge_escalate_ticks ->
        if FFmpegPort.running?(pid) do
          rebuild(
            %{state | bridge_stale_ticks: nil},
            "the ring stayed stale past a bridge bounce"
          )
        else
          # ffmpeg is still climbing its own backoff ladder; that is an outage,
          # and the tick counter waits for it rather than counting it.
          state
        end

      {_pid, ticks} ->
        %{state | bridge_stale_ticks: ticks + 1}
    end
  end

  defp rebuild(state, why) do
    if debounced?(state) do
      state
    else
      Logger.warning("camera #{state.camera.id}: #{why}, rebuilding the pipeline")

      state
      |> set_status(:stalled)
      |> stop_pipeline()
      |> Map.put(:rebuilt_at_ms, now_ms())
      |> start_pipeline(:stall_bounce)
    end
  end

  # One rebuild per stall window: a fresh pipeline needs a connect and a GOP
  # before it can put anything in the ring, so a second rebuild inside that
  # window punishes a pipeline that has not yet had the chance to fail.
  defp debounced?(%{rebuilt_at_ms: nil}), do: false
  defp debounced?(state), do: now_ms() - state.rebuilt_at_ms < stall_ms(state)

  # `nil` is not automatically healthy: a pipeline that wedges before its
  # FIRST fragment would otherwise never trip the watchdog — nothing rebuilds
  # per reconnect anymore, so nothing else would ever clear it. The pipeline's
  # own start stands in for the missing fragment timestamp; the escalation
  # rules still require a connected source before any of this becomes a
  # rebuild, so a camera that is merely down stays exempt. An empty ring
  # cannot pair with an OLD start: the ring is upstream of this process in
  # the camera's :rest_for_one, so a ring restart restarts the owner too.
  defp ring_stale?(state) do
    since = last_fragment_at(state.camera.id) || state.pipeline_started_at_ms

    case since do
      nil -> false
      at -> now_ms() - at > stall_ms(state)
    end
  end

  # The ring is a sibling in the camera's tree and can be restarting; a
  # watchdog that exited on that would take the pipeline down with it, which is
  # the opposite of its job.
  defp last_fragment_at(camera_id) do
    RingBuffer.last_fragment_at(camera_id)
  catch
    :exit, _absent_or_slow -> nil
  end

  defp detect_stale?(%{detect_at_ms: nil}), do: false

  defp detect_stale?(state) do
    detecting?(state) and now_ms() - state.detect_at_ms > stall_ms(state)
  end

  defp bridge?(state), do: state.camera.ingest == :ffmpeg

  defp stall_ms(state), do: state.config.stall_seconds * 1_000

  defp schedule_watchdog(state) do
    interval = Keyword.get(state.opts, :watchdog_interval_ms, 5_000)
    Process.send_after(self(), :watchdog, interval)
  end

  defp set_status(%{status: status} = state, status), do: state

  defp set_status(state, status) do
    status_fun = Keyword.get(state.opts, :status_fun, &CameraStatus.set/2)
    status_fun.(state.camera.id, status)
    %{state | status: status}
  end

  defp backoff_min(state), do: Keyword.get(state.opts, :backoff_min_ms, @backoff_min_ms)
  defp backoff_max(state), do: Keyword.get(state.opts, :backoff_max_ms, @backoff_max_ms)

  defp now_ms, do: System.monotonic_time(:millisecond)
end
