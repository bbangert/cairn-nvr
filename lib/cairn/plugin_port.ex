defmodule Cairn.PluginPort do
  @moduledoc """
  Owns one camera's inference plugin process as a Port.

  Contract (see `docs/plugin-contract.md`): configuration via argv
  (`--camera-id`, `--udp-port`, `--min-score-json`, plus anything already in
  the configured command), H.264 RTP input on the assigned UDP port, ndjson
  lines on stdout, logs on stderr (redirected to
  `{data_dir}/log/plugin-{camera}.log` by the sh wrapper).

  Every line goes through `Cairn.PluginProtocol.decode_line/2` (protocol v1
  or the v0 `{"pts", "dets"}` shape). A `frame.objects` line becomes a
  `Cairn.Observation` forwarded to `Cairn.DetectionAggregator` together with
  the camera's config and effective windows, so the aggregator never has to
  look up config; `plugin.hello` is recorded here and `plugin.status` lands
  in `Cairn.CameraStatus`. Lines that do not match the contract are dropped,
  as are observations from a stream epoch that is no longer current —
  counted always, logged periodically. Exit -> jittered backoff respawn,
  same policy as `Cairn.FFmpegPort`.

  The port also writes the *control channel* on the plugin's stdin: one
  `stream.started` per served camera after every spawn and on every epoch
  change, preceded by `stream.ended` when this plugin process was told about
  a live prior epoch. Writes never block and are never retried — a plugin
  that does not read its stdin loses control lines, nothing else.
  """

  use GenServer

  require Logger

  alias Cairn.{Observation, PluginProtocol, StreamEpochs}

  @backoff_min_ms 1_000
  @backoff_max_ms 30_000
  @max_line 65_536
  # A broken plugin produces a drop per frame — thousands per line, if the line
  # is one long list of invalid dets — and this log shares its volume with the
  # recordings. Time, not a drop count, is what has to bound the log rate: a
  # counter limiter emits once per burst, and bursts are attacker-sized.
  @drop_log_interval_ms 5_000

  defstruct camera: nil,
            config: nil,
            index: 0,
            port: nil,
            os_pid: nil,
            backoff_ms: nil,
            skipping_long_line: false,
            drops: %{},
            last_drop_log_ms: nil,
            plugin: nil,
            last_sequence: nil,
            epoch: nil,
            opts: []

  def start_link(opts) do
    cam = Keyword.fetch!(opts, :camera)
    GenServer.start_link(__MODULE__, opts, name: Cairn.Registry.via(cam.id, :plugin))
  end

  @doc "Argv for the camera's inline plugin command plus contract arguments."
  @spec build_argv(Cairn.Config.Camera.t(), pos_integer()) :: [String.t()]
  def build_argv(%Cairn.Config.Camera{plugin: {:inline, argv}} = cam, udp_port) do
    argv ++
      [
        "--camera-id",
        cam.id,
        "--udp-port",
        Integer.to_string(udp_port),
        "--min-score-json",
        Jason.encode!(cam.min_score)
      ]
  end

  # -- server -----------------------------------------------------------------

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    StreamEpochs.subscribe()

    state = %__MODULE__{
      camera: Keyword.fetch!(opts, :camera),
      config: Keyword.fetch!(opts, :config),
      index: Keyword.get(opts, :index, 0),
      backoff_ms: Keyword.get(opts, :backoff_min_ms, @backoff_min_ms),
      opts: opts
    }

    send(self(), :spawn)
    {:ok, state}
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
    unless state.skipping_long_line do
      Logger.warning("camera #{state.camera.id}: plugin line > #{@max_line} bytes, dropping")
    end

    {:noreply, %{state | skipping_long_line: true}}
  end

  def handle_info({:stream_epoch, camera_id, epoch, reason}, %{camera: %{id: camera_id}} = state) do
    {:noreply, announce_epoch(state, epoch, reason)}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("camera #{state.camera.id}: plugin exited with status #{status}")
    {:noreply, enter_backoff(%{state | port: nil, os_pid: nil})}
  end

  def handle_info({:EXIT, port, _reason}, %{port: port} = state) do
    {:noreply, enter_backoff(%{state | port: nil, os_pid: nil})}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    kill_port(state)
    :ok
  end

  # -- internals --------------------------------------------------------------

  defp handle_line(line, state) do
    case PluginProtocol.decode_line(line, :camera) do
      {:objects, observation} -> observe(state, observation)
      {:hello, hello} -> note_hello(state, hello)
      {:status, status} -> note_status(state, status)
      {:ignore, _reason} -> state
      # `reason` comes from `Cairn.PluginProtocol`'s own closed set of atoms,
      # never from the line, so it is safe as a drop class.
      {:error, reason} -> note_drops(state, 1, reason)
    end
  end

  defp observe(state, observation) do
    observation = attribute(observation, state.camera.id)

    if current_epoch?(observation, state.camera.id) do
      state
      |> note_sequence(observation)
      |> forward(observation)
      |> note_drops(observation.invalid_objects, :invalid_det)
    else
      note_drops(state, 1, :stale_epoch)
    end
  end

  # v0 lines carry neither epoch nor time: the epoch is whatever is current
  # right now, and arrival is the only timestamp available.
  defp attribute(%Observation{protocol: :v0} = observation, camera_id) do
    epoch =
      case StreamEpochs.current(camera_id) do
        {:ok, epoch} -> epoch
        :unknown -> nil
      end

    %{
      observation
      | camera_id: camera_id,
        plugin_instance: camera_id,
        epoch: epoch,
        observed_at: DateTime.utc_now(),
        time_quality: :arrival
    }
  end

  defp attribute(observation, camera_id),
    do: %{observation | camera_id: camera_id, plugin_instance: camera_id}

  # v0 observations were stamped with the current epoch a line ago, so only a
  # plugin-supplied (v1) epoch can be stale here.
  defp current_epoch?(%Observation{protocol: :v0}, _camera_id), do: true

  defp current_epoch?(%Observation{epoch: epoch}, camera_id),
    do: StreamEpochs.current(camera_id) == {:ok, epoch}

  # A gap means frames were lost between plugin and host — counted, never a
  # reason to drop the line that revealed it. It shares the drop counters so a
  # plugin that skips every other sequence cannot outrun the log rate limit.
  defp note_sequence(state, %Observation{sequence: nil}), do: state

  defp note_sequence(%{last_sequence: last} = state, %Observation{sequence: sequence})
       when is_integer(last) and sequence > last + 1 do
    gap = sequence - last - 1

    :telemetry.execute([:cairn, :plugin, :sequence_gap], %{count: gap}, %{
      camera_id: state.camera.id
    })

    %{note_drops(state, gap, :sequence_gap) | last_sequence: sequence}
  end

  defp note_sequence(state, %Observation{sequence: sequence}),
    do: %{state | last_sequence: sequence}

  defp forward(state, observation) do
    windows = Cairn.Config.windows(state.config, state.camera)
    aggregator = Keyword.get(state.opts, :aggregator, Cairn.DetectionAggregator)
    Cairn.DetectionAggregator.detections(aggregator, state.camera, windows, observation)
    state
  end

  defp note_hello(state, hello) do
    Logger.info(
      "camera #{state.camera.id}: plugin hello — #{hello["name"] || "unnamed"} " <>
        "#{hello["version"] || "?"}, capabilities #{inspect(hello["capabilities"])}"
    )

    case hello["supported_versions"] do
      versions when is_list(versions) ->
        unless 1 in versions do
          Logger.warning(
            "camera #{state.camera.id}: plugin does not list protocol 1 in " <>
              "supported_versions (#{inspect(versions)})"
          )
        end

      _absent ->
        :ok
    end

    %{state | plugin: hello}
  end

  defp note_status(state, status) do
    Cairn.CameraStatus.set_plugin_status(state.camera.id, status)
    state
  end

  # Counted per reason class, always; logged at most once per
  # @drop_log_interval_ms, summarizing every class seen so far. The counters
  # reset with the OS process, so a fixed plugin logs again after its restart.
  # `class` is a fixed atom — never plugin-supplied data, which would make the
  # map a plugin-growable term.
  defp note_drops(state, 0, _class), do: state

  defp note_drops(state, count, class) do
    drops = Map.update(state.drops, class, count, &(&1 + count))
    now = System.monotonic_time(:millisecond)

    if state.last_drop_log_ms == nil or now - state.last_drop_log_ms >= @drop_log_interval_ms do
      Logger.warning("camera #{state.camera.id}: dropped lines/dets: #{summarize_drops(drops)}")
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

  # -- control channel --------------------------------------------------------

  # Told once per spawn from ETS (the loss-proof path: a broadcast sent while
  # no plugin was running is simply not there to receive) and again on every
  # broadcast. `state.epoch` is what *this* plugin process has been told, so
  # it both suppresses the duplicate and knows whether an `ended` is owed.
  #
  # `:camera_stopped` mints an epoch nothing streams under, so it ends the
  # prior stream and starts nothing; it is still recorded, so the next real
  # epoch is announced as a start rather than as a replacement.
  defp announce_epoch(state, epoch, reason) do
    state =
      case state.epoch do
        {^epoch, _liveness} ->
          state

        {prior, :live} ->
          state
          |> write_control(stream_ended(state.camera.id, prior, reason))
          |> maybe_start(epoch, reason)

        _none ->
          maybe_start(state, epoch, reason)
      end

    %{state | epoch: {epoch, liveness(reason)}}
  end

  defp maybe_start(state, _epoch, :camera_stopped), do: state

  defp maybe_start(state, epoch, _reason),
    do: write_control(state, stream_started(state.camera.id, epoch))

  defp liveness(:camera_stopped), do: :ended
  defp liveness(_reason), do: :live

  # The epoch in ETS at spawn time may belong to a stopped camera; the plugin
  # is told the stream started either way and simply sees no packets, which
  # the contract already requires it to tolerate.
  defp announce_current_epoch(state) do
    case StreamEpochs.current(state.camera.id) do
      {:ok, epoch} -> announce_epoch(state, epoch, :started)
      :unknown -> state
    end
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
  # blocking this GenServer: a full port queue drops the line and is counted.
  defp write_control(%{port: nil} = state, _line), do: state

  defp write_control(state, line) do
    result =
      try do
        Port.command(state.port, [line, "\n"], [:nosuspend])
      rescue
        ArgumentError -> :closed
      end

    case result do
      true -> state
      false -> note_drops(state, 1, :control_stdin_busy)
      :closed -> note_drops(state, 1, :control_stdin_closed)
    end
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
    announce_current_epoch(%{
      state
      | port: port,
        os_pid: os_pid,
        skipping_long_line: false,
        drops: %{},
        last_drop_log_ms: nil,
        last_sequence: nil,
        epoch: nil,
        plugin: nil
    })
  end

  defp spawn_command(state) do
    case Keyword.get(state.opts, :command) do
      nil ->
        log =
          Path.join(Cairn.DataDir.log_dir(state.config.data_dir), "plugin-#{state.camera.id}.log")

        {plugin_port, _rtp_port} = Cairn.UDPPorts.ports_for(state.config, state.index)

        state.camera
        |> build_argv(plugin_port)
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
