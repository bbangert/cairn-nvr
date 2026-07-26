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
  config. Malformed lines are logged and dropped. Exit -> jittered backoff
  respawn, same policy as `Cairn.FFmpegPort`.
  """

  use GenServer

  require Logger

  @backoff_min_ms 1_000
  @backoff_max_ms 30_000
  @max_line 8_192

  defstruct camera: nil,
            config: nil,
            index: 0,
            port: nil,
            os_pid: nil,
            backoff_ms: nil,
            skipping_long_line: false,
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
      handle_line(line, state)
      {:noreply, state}
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
      {:ok, %{"pts" => pts, "dets" => dets}} when is_list(dets) ->
        forward(state, pts, dets)

      {:ok, _other} ->
        Logger.warning("camera #{state.camera.id}: plugin line missing pts/dets, dropped")

      {:error, _} ->
        Logger.warning("camera #{state.camera.id}: malformed plugin line dropped")
    end
  end

  defp forward(state, pts, dets) do
    dets =
      for %{"label" => label, "score" => score, "bbox" => bbox} <- dets,
          is_binary(label) and is_number(score) and is_list(bbox) do
        %{label: label, score: score / 1, bbox: bbox}
      end

    windows = Cairn.Config.windows(state.config, state.camera)
    aggregator = Keyword.get(state.opts, :aggregator, Cairn.DetectionAggregator)
    Cairn.DetectionAggregator.detections(aggregator, state.camera, windows, pts, dets)
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

    %{state | port: port, os_pid: os_pid, skipping_long_line: false}
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
