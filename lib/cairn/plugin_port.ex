defmodule Cairn.PluginPort do
  @moduledoc """
  Owns one camera's inference plugin process as a Port.

  Contract (see `docs/plugin-contract.md`): configuration via argv
  (`--camera-id`, `--udp-port`, `--min-score-json`, plus anything already in
  the configured command), H.264 RTP input on the assigned UDP port, ndjson
  detection lines on stdout, logs on stderr (redirected to
  `{data_dir}/log/plugin-{camera}.log` by the sh wrapper).

  Each decoded line (`{"pts": _, "dets": [{"label", "score", "bbox"}]}`)
  is forwarded to `Cairn.DetectionAggregator` together with the camera's
  config and effective windows, so the aggregator never has to look up
  config. Lines that do not match the contract are dropped, as are
  individual detections `Cairn.PluginProtocol` rejects — counted always,
  logged periodically. Exit -> jittered backoff respawn, same policy as
  `Cairn.FFmpegPort`.
  """

  use GenServer

  require Logger

  alias Cairn.PluginProtocol

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
    case Jason.decode(line) do
      {:ok, %{"pts" => pts, "dets" => dets}} when is_number(pts) and is_list(dets) ->
        forward(state, pts, dets)

      {:ok, %{"pts" => _pts, "dets" => dets}} when is_list(dets) ->
        note_drops(state, 1, :non_numeric_pts)

      {:ok, _other} ->
        note_drops(state, 1, :missing_fields)

      {:error, _} ->
        note_drops(state, 1, :malformed_line)
    end
  end

  defp forward(state, pts, dets) do
    {dets, invalid} = PluginProtocol.validate_dets(dets)

    windows = Cairn.Config.windows(state.config, state.camera)
    aggregator = Keyword.get(state.opts, :aggregator, Cairn.DetectionAggregator)
    Cairn.DetectionAggregator.detections(aggregator, state.camera, windows, pts, dets)

    note_drops(state, invalid, :invalid_det)
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

    %{
      state
      | port: port,
        os_pid: os_pid,
        skipping_long_line: false,
        drops: %{},
        last_drop_log_ms: nil
    }
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
