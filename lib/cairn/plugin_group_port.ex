defmodule Cairn.PluginGroupPort do
  @moduledoc """
  Owns one plugin group's OS process as a Port: a single plugin serving every
  camera that references it by name.

  Contract (see `docs/plugin-contract.md`): configuration via argv
  (`--cameras-json`, a JSON array of `{id, udp_port, min_score}` — one entry
  per member camera — plus anything already in the configured command), one
  H.264 RTP input per member on that member's UDP port, ndjson lines on
  stdout, logs on stderr (redirected to `{data_dir}/log/plugin-{group}.log`
  by the sh wrapper).

  Every detection line must carry `camera_id`; decoded by
  `Cairn.PluginProtocol.decode_line/2` (protocol v1 or the v0
  `{"camera_id", "pts", "dets"}` shape) it is routed as a
  `Cairn.Observation` to `Cairn.DetectionAggregator` with that camera's
  config and effective policy (event windows, tracking bounds and the
  `track:` / `record:` tiers). Lines for an unknown
  or missing camera are dropped, as are malformed ones, observations from a
  stale stream epoch and
  individual detections `Cairn.PluginProtocol` rejects — counted always,
  logged periodically. Exit -> jittered backoff respawn, same policy as
  `Cairn.PluginPort`.

  The control channel on the plugin's stdin is per member camera: one
  `stream.started` for every member after each spawn, and `stream.ended` +
  `stream.started` as each member's epoch changes. An epoch is never a
  reason to restart the group — one member's stream bouncing must not touch
  the other members' inference.

  The whole group shares one failure domain: a crash restarts every member's
  stream. Membership and argv are fixed for the process's lifetime — a config
  change to either restarts the group. Camera fields the argv does not carry
  (the `post` and `max` windows, the tracking bounds, the `track:` / `record:`
  tiers, retention, the camera struct itself) are refreshed in place by
  `refresh/3` instead (see `Cairn.PluginGroupSupervisor`). `pre` is the one
  window that is not refresh-only: it restarts the member camera — its ring
  is sized at tree init — though never this group process.
  """

  use GenServer

  require Logger

  alias Cairn.Config
  alias Cairn.Observation
  alias Cairn.PluginProtocol
  alias Cairn.StreamEpochs

  @backoff_min_ms 1_000
  @backoff_max_ms 30_000
  @max_line 65_536
  # A plugin pointed at the wrong group produces an undeliverable line per
  # frame per camera — and one line of invalid dets is thousands of drops on
  # its own — while this log shares its volume with the recordings. Time, not
  # a drop count, is what has to bound the log rate: a counter limiter emits
  # once per burst, and bursts are attacker-sized.
  @drop_log_interval_ms 5_000
  @id_preview 64
  # Beyond this the plugin's clock is not the host's, and `observed_at` sets
  # event start times while the host clock closes them: a skewed plugin yields
  # negative durations, snapshot seeks outside the segment, and future-dated
  # events that retention never prunes.
  @max_clock_skew_ms 30_000
  # A status is retained in ETS and broadcast to every subscriber — per member
  # when the line names none — so an unchanged one is only re-sent as a
  # liveness heartbeat at this interval.
  @status_min_interval_ms 5_000

  defstruct group: nil,
            config: nil,
            routes: %{},
            port: nil,
            os_pid: nil,
            backoff_ms: nil,
            skipping_long_line: false,
            drops: %{},
            last_drop_log_ms: nil,
            plugin: nil,
            last_sequences: %{},
            last_statuses: %{},
            epochs: %{},
            opts: []

  def start_link(opts) do
    group = Keyword.fetch!(opts, :group)
    GenServer.start_link(__MODULE__, opts, name: Cairn.Registry.via(group.name, :plugin_group))
  end

  @doc "Argv for the configured plugin command plus contract arguments."
  @spec build_argv(Config.PluginGroup.t()) :: [String.t()]
  def build_argv(%Config.PluginGroup{} = group) do
    group.command ++ ["--cameras-json", Jason.encode!(group.members)]
  end

  @doc """
  Point a running group at a new config without touching its OS process.

  Camera fields the launch argv does not carry — the `post` and `max` event
  windows, the tracking bounds, the `track:` / `record:` tiers, retention, the
  camera struct handed to the aggregator — change on reload without changing
  the group, so the routing map (each member's camera paired with its
  `Cairn.Config.policy/2`) has to be rebuilt in place. (`pre` rides along in
  that policy map, but a `pre` change never arrives here alone: it restarts
  the member camera, whose ring is sized at tree init.) Restarting an
  accelerator-holding process over Elixir-side state is exactly what the
  restart-only-on-config-change policy exists to avoid, and it would cut every
  live track on every member.
  """
  @spec refresh(GenServer.server(), Config.PluginGroup.t(), Config.t()) :: :ok
  def refresh(server, %Config.PluginGroup{} = group, %Config{} = config) do
    GenServer.cast(server, {:refresh, group, config})
  end

  # -- server -----------------------------------------------------------------

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    StreamEpochs.subscribe()

    group = Keyword.fetch!(opts, :group)
    config = Keyword.fetch!(opts, :config)

    state = %__MODULE__{
      group: group,
      config: config,
      routes: build_routes(group, config),
      backoff_ms: Keyword.get(opts, :backoff_min_ms, @backoff_min_ms),
      opts: opts
    }

    send(self(), :spawn)
    {:ok, state}
  end

  @impl true
  def handle_cast({:refresh, group, config}, state) do
    {:noreply, %{state | group: group, config: config, routes: build_routes(group, config)}}
  end

  @impl true
  def handle_info(:spawn, state) do
    {:noreply, spawn_plugin(state)}
  end

  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    if state.skipping_long_line do
      {:noreply, %{state | skipping_long_line: false}}
    else
      {:noreply, handle_line(line, state)}
    end
  end

  def handle_info({port, {:data, {:noeol, _partial}}}, %{port: port} = state) do
    if !state.skipping_long_line do
      Logger.warning("plugin group #{state.group.name}: line > #{@max_line} bytes, dropping")
    end

    {:noreply, %{state | skipping_long_line: true}}
  end

  # Never a restart: the group keeps running and the member's plugin state is
  # reset through the control channel instead.
  def handle_info({:stream_epoch, camera_id, epoch, reason}, state) do
    cond do
      not Map.has_key?(state.routes, camera_id) -> {:noreply, state}
      superseded?(Map.get(state.epochs, camera_id), epoch) -> {:noreply, state}
      true -> {:noreply, announce_epoch(state, camera_id, epoch, reason)}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("plugin group #{state.group.name}: plugin exited with status #{status}")
    {:noreply, enter_backoff(%{state | port: nil, os_pid: nil})}
  end

  # A port can die with its OS process still alive — `:epipe` on a control
  # write to a plugin that closed stdin is exactly that — and the orphan
  # keeps every member's UDP port bound, so the respawn would never see RTP.
  def handle_info({:EXIT, port, _reason}, %{port: port} = state) do
    {:noreply, enter_backoff(kill_port(state))}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    kill_port(state)
    :ok
  end

  # -- internals --------------------------------------------------------------

  defp build_routes(group, config) do
    cameras = Map.new(config.cameras, &{&1.id, &1})

    Enum.reduce(group.members, %{}, fn member, routes ->
      case Map.fetch(cameras, member.id) do
        {:ok, cam} ->
          Map.put(routes, cam.id, {cam, Config.policy(config, cam)})

        :error ->
          Logger.error(
            "plugin group #{group.name}: member #{member.id} is not a configured camera"
          )

          routes
      end
    end)
  end

  # The codec is total by construction and the dispatch below is host code,
  # but neither is worth the group's life: a plugin respawn replays the line
  # that killed it, and one line would then cost every member's inference.
  # A line can cost a drop; it can never cost the process.
  defp handle_line(line, state) do
    decode_and_dispatch(line, state)
  rescue
    exception ->
      Logger.error(
        "plugin group #{state.group.name}: plugin line raised " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      note_drops(state, 1, :codec_crash)
  catch
    kind, reason ->
      Logger.error("plugin group #{state.group.name}: plugin line #{kind} #{inspect(reason)}")
      note_drops(state, 1, :codec_crash)
  end

  defp decode_and_dispatch(line, state) do
    case PluginProtocol.decode_line(line, :group) do
      {:objects, observation} -> route(state, observation)
      {:hello, hello} -> note_hello(state, hello)
      {:status, status} -> note_status(state, status)
      {:ignore, _reason} -> state
      # `reason` comes from `Cairn.PluginProtocol`'s own closed set of atoms,
      # never from the line, so it is safe as a drop class.
      {:error, reason} -> note_drops(state, 1, reason)
    end
  end

  defp route(state, observation) do
    case Map.fetch(state.routes, observation.camera_id) do
      {:ok, {cam, policy}} ->
        observe(state, cam, policy, observation)

      :error ->
        note_drops(state, 1, :unknown_camera, preview(observation.camera_id))
    end
  end

  defp observe(state, cam, policy, observation) do
    {observation, skew} =
      observation
      |> attribute(cam.id, state.group.name, tracking?(state.plugin))
      |> clamp_observed_at()

    state = note_drops(state, skew, :clock_skew, preview(cam.id))

    if current_epoch?(observation, cam.id) do
      state
      |> note_sequence(observation)
      |> forward(cam, policy, observation)
      |> note_drops(observation.invalid_objects, :invalid_det)
    else
      note_drops(state, 1, :stale_epoch, preview(cam.id))
    end
  end

  # v0 lines carry neither epoch nor time: the epoch is whatever is current
  # right now, and arrival is the only timestamp available.
  defp attribute(%Observation{protocol: :v0} = observation, camera_id, group_name, tracking) do
    epoch =
      case StreamEpochs.current(camera_id) do
        {:ok, epoch} -> epoch
        :unknown -> nil
      end

    %{
      observation
      | camera_id: camera_id,
        plugin_instance: group_name,
        epoch: epoch,
        observed_at: DateTime.utc_now(),
        time_quality: :arrival,
        tracking: tracking
    }
  end

  defp attribute(observation, camera_id, group_name, tracking),
    do: %{
      observation
      | camera_id: camera_id,
        plugin_instance: group_name,
        tracking: tracking
    }

  # Track ids are only honoured from a plugin that promised, in its hello,
  # that they are stable (see `Cairn.Tracker`). One process, one promise: it
  # covers every member camera.
  defp tracking?(%{"capabilities" => %{"object_tracking" => true}}), do: true
  defp tracking?(_hello), do: false

  # `observed_at` is the plugin's own clock and it is what event `started_at`,
  # label offsets and snapshot seeks derive from, while `ended_at` and the
  # event timers are the host's. Past @max_clock_skew_ms apart they are not
  # the same clock, so the host's is substituted and the timing is honestly
  # reported as arrival quality.
  defp clamp_observed_at(%Observation{observed_at: %DateTime{} = at} = observation) do
    now = DateTime.utc_now()

    if abs(DateTime.diff(at, now, :millisecond)) > @max_clock_skew_ms do
      {%{observation | observed_at: now, time_quality: :arrival}, 1}
    else
      {observation, 0}
    end
  end

  defp clamp_observed_at(observation), do: {observation, 0}

  # v0 observations were stamped with the current epoch a line ago, so only a
  # plugin-supplied (v1) epoch can be stale here.
  defp current_epoch?(%Observation{protocol: :v0}, _camera_id), do: true

  defp current_epoch?(%Observation{epoch: epoch}, camera_id),
    do: StreamEpochs.current(camera_id) == {:ok, epoch}

  # A gap means frames were lost between plugin and host — counted, never a
  # reason to drop the line that revealed it. It shares the drop counters so a
  # plugin that skips every other sequence cannot outrun the log rate limit.
  #
  # Each member's baseline is held together with the epoch it was observed
  # under, and a new epoch re-baselines instead of comparing: an epoch is a
  # new sequence timeline (the contract lets a plugin restart the counter at 0
  # for each one), and that member's last line under the retired epoch —
  # refused as `:stale_epoch` — consumed a number no accepted line will ever
  # account for. Comparing across the boundary reports that refusal a second
  # time as a lost frame, which is not what happened.
  defp note_sequence(state, %Observation{sequence: nil}), do: state

  defp note_sequence(state, %Observation{} = observation) do
    %Observation{camera_id: camera_id, epoch: epoch, sequence: sequence} = observation

    case Map.get(state.last_sequences, camera_id) do
      {^epoch, last} when sequence > last + 1 ->
        note_gap(state, observation, sequence - last - 1)

      _first_or_new_epoch ->
        put_in(state.last_sequences[camera_id], {epoch, sequence})
    end
  end

  defp note_gap(state, observation, gap) do
    :telemetry.execute([:cairn, :plugin, :sequence_gap], %{count: gap}, %{
      camera_id: observation.camera_id
    })

    state = note_drops(state, gap, :sequence_gap, preview(observation.camera_id))
    put_in(state.last_sequences[observation.camera_id], {observation.epoch, observation.sequence})
  end

  # The codec bounds every field of `hello`, and these are logged through
  # `inspect/2` anyway: nothing plugin-supplied is interpolated raw, so no
  # value shape can raise `Protocol.UndefinedError` here.
  defp note_hello(state, hello) do
    Logger.info(
      "plugin group #{state.group.name}: plugin hello — #{preview(hello["name"])} " <>
        "#{preview(hello["version"])}, capabilities #{preview(hello["capabilities"])}"
    )

    case hello["supported_versions"] do
      versions when is_list(versions) ->
        if 1 not in versions do
          Logger.warning(
            "plugin group #{state.group.name}: plugin does not list protocol 1 in " <>
              "supported_versions (#{preview(versions)})"
          )
        end

      _absent ->
        :ok
    end

    %{state | plugin: hello}
  end

  # One process serves every member, so a status without a `camera_id` is
  # about the process and applies to all of them.
  defp note_status(state, status) do
    case status["camera_id"] do
      camera_id when is_binary(camera_id) ->
        if Map.has_key?(state.routes, camera_id) do
          push_status(state, camera_id, status)
        else
          note_drops(state, 1, :unknown_camera, preview(camera_id))
        end

      _none ->
        Enum.reduce(Map.keys(state.routes), state, &push_status(&2, &1, status))
    end
  end

  # An unchanged status is an ETS write plus a broadcast to every dashboard
  # and SSE client per line — multiplied by member count when the line names
  # no camera — so it is re-sent only as a slow heartbeat.
  defp push_status(state, camera_id, status) do
    # `camera_id` has finished its routing job in `note_status/2`; what is
    # stored is keyed by camera already, so carrying it in the payload only
    # duplicates the key (and would differ from an unrouted status that is
    # otherwise identical, defeating the change detection below).
    status = Map.delete(status, "camera_id")
    now = System.monotonic_time(:millisecond)

    if status_due?(status, Map.get(state.last_statuses, camera_id), now) do
      Cairn.CameraStatus.set_plugin_status(camera_id, status)
      put_in(state.last_statuses[camera_id], {status, now})
    else
      note_drops(state, 1, :status_rate_limited, preview(camera_id))
    end
  end

  defp status_due?(_status, nil, _now), do: true

  defp status_due?(status, {last, last_ms}, now),
    do: status != last or now - last_ms >= @status_min_interval_ms

  # Counted per reason class, always; logged at most once per
  # @drop_log_interval_ms, summarizing every class seen so far. The counters
  # reset with the OS process, so a fixed plugin logs again after its restart.
  # `class` is a fixed atom — never plugin-supplied data, which would make the
  # map a plugin-growable term. Plugin-supplied `detail` stays in the message.
  defp note_drops(state, count, class, detail \\ nil)

  defp note_drops(state, 0, _class, _detail), do: state

  defp note_drops(state, count, class, detail) do
    drops = Map.update(state.drops, class, count, &(&1 + count))
    now = System.monotonic_time(:millisecond)

    if state.last_drop_log_ms == nil or now - state.last_drop_log_ms >= @drop_log_interval_ms do
      Logger.warning(
        "plugin group #{state.group.name}: dropped lines/dets: " <>
          summarize_drops(drops) <> latest_detail(class, detail)
      )

      %{state | drops: drops, last_drop_log_ms: now}
    else
      %{state | drops: drops}
    end
  end

  defp summarize_drops(drops) do
    total = drops |> Map.values() |> Enum.sum()
    detail = Enum.map_join(Enum.sort(drops), ", ", fn {class, n} -> "#{class} ×#{n}" end)
    "#{detail} (#{total} total)"
  end

  defp latest_detail(_class, nil), do: ""
  defp latest_detail(class, detail), do: "; latest #{class}: #{detail}"

  # Plugin-supplied values can be any JSON term up to the line limit.
  # `inspect/2` escapes control bytes (no forged log lines) and
  # `printable_limit` bounds a binary by *bytes* — `String.slice/3` would not,
  # since one grapheme cluster can be arbitrarily long.
  defp preview(value), do: inspect(value, limit: 3, printable_limit: @id_preview)

  defp forward(state, cam, policy, observation) do
    aggregator = Keyword.get(state.opts, :aggregator, Cairn.DetectionAggregator)
    Cairn.DetectionAggregator.detections(aggregator, cam, policy, observation)
    state
  end

  defp spawn_plugin(state) do
    command = spawn_command(state)

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        {:line, @max_line},
        args: ["-c", command]
      ])

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        nil -> nil
      end

    # A fresh plugin process has been told nothing and continues nobody's
    # sequence: both reset with the OS process, as do the drop counters.
    announce_current_epochs(%{
      state
      | port: port,
        os_pid: os_pid,
        skipping_long_line: false,
        drops: %{},
        last_drop_log_ms: nil,
        last_sequences: %{},
        last_statuses: %{},
        epochs: %{},
        plugin: nil
    })
  end

  # -- control channel --------------------------------------------------------

  # Told once per spawn from ETS (the loss-proof path: a broadcast sent while
  # no plugin was running is simply not there to receive) and again on every
  # broadcast. `state.epochs` is what *this* plugin process has been told per
  # member, so it both suppresses the duplicate and knows whether an `ended`
  # is owed.
  #
  # `:camera_stopped` mints an epoch nothing streams under, so it ends the
  # prior stream and starts nothing; it is still recorded, so the next real
  # epoch is announced as a start rather than as a replacement.
  #
  # A write the plugin never received is not an announcement: recording it
  # anyway would leave the plugin tagging that member's lines with an epoch
  # the host does not expect, and `current_epoch?/2` would then drop every
  # one of them until the *next* epoch change. On a failed write the
  # member's last-sent state is left where it was, so the next broadcast (or
  # the next spawn's ETS pull) re-announces.
  defp announce_epoch(state, camera_id, epoch, reason) do
    case Map.get(state.epochs, camera_id) do
      {^epoch, _liveness} ->
        state

      {prior, :live} ->
        case write_control(state, stream_ended(camera_id, prior, reason)) do
          {:ok, state} ->
            state = put_in(state.epochs[camera_id], {prior, :ended})
            start_and_record(state, camera_id, epoch, reason)

          {:error, state} ->
            state
        end

      _none ->
        start_and_record(state, camera_id, epoch, reason)
    end
  end

  defp start_and_record(state, camera_id, epoch, reason) do
    case maybe_start(state, camera_id, epoch, reason) do
      {:ok, state} -> put_in(state.epochs[camera_id], {epoch, liveness(reason)})
      {:error, state} -> state
    end
  end

  defp maybe_start(state, _camera_id, _epoch, :camera_stopped), do: {:ok, state}

  defp maybe_start(state, camera_id, epoch, _reason),
    do: write_control(state, stream_started(camera_id, epoch))

  defp liveness(:camera_stopped), do: :ended
  defp liveness(_reason), do: :live

  # An epoch older than the one this plugin process was already told about
  # for that member is ignored (see `Cairn.ULID.superseded?/2`): announcing
  # it would leave the plugin tagging that member's lines with a dead epoch
  # while `current_epoch?/2` compares against ETS, so every one of its
  # observations would be dropped as `:stale_epoch` until the next respawn.
  defp superseded?(nil, _epoch), do: false
  defp superseded?({held, _liveness}, epoch), do: Cairn.ULID.superseded?(held, epoch)

  # The epoch in ETS at spawn time may belong to a stopped camera; the plugin
  # is told the stream started either way and simply sees no packets on that
  # member's port, which the contract already requires it to tolerate.
  defp announce_current_epochs(state) do
    Enum.reduce(Map.keys(state.routes), state, fn camera_id, state ->
      case StreamEpochs.current(camera_id) do
        {:ok, epoch} -> announce_epoch(state, camera_id, epoch, :started)
        :unknown -> state
      end
    end)
  end

  defp stream_started(camera_id, epoch) do
    Jason.encode!(%{
      "spec" => "cairn.plugin",
      "version" => 1,
      "type" => "stream.started",
      "camera_id" => camera_id,
      "stream_epoch" => epoch,
      "rtp" => %{"clock_rate" => 90_000}
    })
  end

  defp stream_ended(camera_id, epoch, reason) do
    Jason.encode!(%{
      "spec" => "cairn.plugin",
      "version" => 1,
      "type" => "stream.ended",
      "camera_id" => camera_id,
      "stream_epoch" => epoch,
      "reason" => to_string(reason)
    })
  end

  # `{:line, _}` is inbound framing only, so the newline is ours to write.
  # `:nosuspend` is what keeps a plugin that never reads its stdin from
  # blocking this GenServer — and with it every other member's detections: a
  # full port queue drops the line and is counted.
  # There is no plugin to tell during backoff; the spawn re-announces from
  # ETS, so this is a loss the caller must not record as an announcement
  # either.
  defp write_control(%{port: nil} = state, _line), do: {:error, state}

  defp write_control(state, line) do
    result =
      try do
        Port.command(state.port, [line, "\n"], [:nosuspend])
      rescue
        ArgumentError -> :closed
      end

    case result do
      true -> {:ok, state}
      false -> {:error, note_drops(state, 1, :control_stdin_busy)}
      :closed -> {:error, note_drops(state, 1, :control_stdin_closed)}
    end
  end

  defp spawn_command(state) do
    case Keyword.get(state.opts, :command) do
      nil ->
        log =
          Path.join(
            Cairn.DataDir.log_dir(state.config.data_dir),
            "plugin-#{state.group.name}.log"
          )

        state.group
        |> build_argv()
        |> Cairn.FFmpegPort.shell_command(log)

      command when is_binary(command) ->
        command
    end
  end

  defp enter_backoff(state) do
    jitter = :rand.uniform()
    delay = trunc(state.backoff_ms * (0.5 + jitter))
    Process.send_after(self(), :spawn, delay)
    max = Keyword.get(state.opts, :backoff_max_ms, @backoff_max_ms)
    %{state | backoff_ms: min(state.backoff_ms * 2, max)}
  end

  defp kill_port(%{port: nil} = state), do: state

  defp kill_port(state) do
    if state.os_pid, do: System.cmd("kill", ["-TERM", "#{state.os_pid}"], stderr_to_stdout: true)

    try do
      Port.close(state.port)
    rescue
      ArgumentError -> :ok
    end

    %{state | port: nil, os_pid: nil}
  end
end
