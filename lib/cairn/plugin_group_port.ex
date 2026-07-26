defmodule Cairn.PluginGroupPort do
  @moduledoc """
  Owns one plugin group's OS process as a Port: a single plugin serving every
  camera that references it by name.

  Contract (see `docs/plugin-contract.md`): configuration via argv
  (`--cameras-json`, a JSON array of `{id, udp_port, min_score}` — one entry
  per member camera — plus anything already in the configured command), one
  H.264 RTP input per member on that member's UDP port, ndjson detection
  lines on stdout, logs on stderr (redirected to
  `{data_dir}/log/plugin-{group}.log` by the sh wrapper).

  Every line must carry `camera_id`; it is routed to
  `Cairn.DetectionAggregator` with that camera's config and effective
  windows. Lines for an unknown or missing camera are dropped, as are
  malformed ones and individual detections `Cairn.PluginProtocol` rejects —
  counted always, logged periodically. Exit -> jittered
  backoff respawn, same policy as `Cairn.PluginPort`.

  The whole group shares one failure domain: a crash restarts every member's
  stream. Membership and argv are fixed for the process's lifetime — a config
  change to either restarts the group. Camera fields the argv does not carry
  (windows, retention, the camera struct itself) are refreshed in place by
  `refresh/3` instead (see `Cairn.PluginGroupSupervisor`).
  """

  use GenServer

  require Logger

  alias Cairn.Config
  alias Cairn.PluginProtocol

  @backoff_min_ms 1_000
  @backoff_max_ms 30_000
  @max_line 65_536
  # A plugin pointed at the wrong group produces an undeliverable line per
  # frame per camera, and this log shares its volume with the recordings.
  @drop_log_every 100
  @id_preview 64

  defstruct group: nil,
            config: nil,
            routes: %{},
            port: nil,
            os_pid: nil,
            backoff_ms: nil,
            skipping_long_line: false,
            drops: 0,
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

  Camera fields the launch argv does not carry — windows, retention, the
  camera struct handed to the aggregator — change on reload without changing
  the group, so the routing map has to be rebuilt in place. Restarting an
  accelerator-holding process over Elixir-side state is exactly what the
  restart-only-on-config-change policy exists to avoid.
  """
  @spec refresh(GenServer.server(), Config.PluginGroup.t(), Config.t()) :: :ok
  def refresh(server, %Config.PluginGroup{} = group, %Config{} = config) do
    GenServer.cast(server, {:refresh, group, config})
  end

  # -- server -----------------------------------------------------------------

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

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
    unless state.skipping_long_line do
      Logger.warning("plugin group #{state.group.name}: line > #{@max_line} bytes, dropping")
    end

    {:noreply, %{state | skipping_long_line: true}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("plugin group #{state.group.name}: plugin exited with status #{status}")
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

  defp build_routes(group, config) do
    cameras = Map.new(config.cameras, &{&1.id, &1})

    Enum.reduce(group.members, %{}, fn member, routes ->
      case Map.fetch(cameras, member.id) do
        {:ok, cam} ->
          Map.put(routes, cam.id, {cam, Config.windows(config, cam)})

        :error ->
          Logger.error(
            "plugin group #{group.name}: member #{member.id} is not a configured camera"
          )

          routes
      end
    end)
  end

  defp handle_line(line, state) do
    case Jason.decode(line) do
      {:ok, %{"camera_id" => camera_id, "pts" => pts, "dets" => dets}}
      when is_number(pts) and is_list(dets) ->
        route(state, camera_id, pts, dets)

      {:ok, _other} ->
        note_drop(state, "line missing camera_id/pts/dets")

      {:error, _} ->
        note_drop(state, "malformed line")
    end
  end

  defp route(state, camera_id, pts, dets) do
    case Map.fetch(state.routes, camera_id) do
      {:ok, {cam, windows}} ->
        forward(state, cam, windows, pts, dets)

      :error ->
        note_drop(state, "line for unknown camera #{preview(camera_id)}")
    end
  end

  # Counted always, logged first and every @drop_log_every-th; the counter
  # resets with the OS process, so a fixed plugin logs again after its restart.
  defp note_drop(state, reason) do
    drops = state.drops + 1

    if rem(drops, @drop_log_every) == 1 do
      Logger.warning("plugin group #{state.group.name}: #{reason}, dropped (#{drops} so far)")
    end

    %{state | drops: drops}
  end

  # `camera_id` is plugin-supplied and can be any JSON value up to the line
  # limit; only a short prefix is worth logging.
  defp preview(camera_id) when is_binary(camera_id),
    do: camera_id |> String.slice(0, @id_preview) |> inspect()

  defp preview(other), do: inspect(other, limit: 3, printable_limit: @id_preview)

  defp forward(state, cam, windows, pts, dets) do
    {dets, invalid} = PluginProtocol.validate_dets(dets)

    aggregator = Keyword.get(state.opts, :aggregator, Cairn.DetectionAggregator)
    Cairn.DetectionAggregator.detections(aggregator, cam, windows, pts, dets)

    note_invalid_dets(state, invalid)
  end

  defp note_invalid_dets(state, 0), do: state

  defp note_invalid_dets(state, count) do
    Enum.reduce(1..count//1, state, fn _, state -> note_drop(state, "invalid det") end)
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

    %{state | port: port, os_pid: os_pid, skipping_long_line: false, drops: 0}
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
