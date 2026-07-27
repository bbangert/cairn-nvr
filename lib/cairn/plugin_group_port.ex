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
  # frame per camera — and one line of invalid dets is thousands of drops on
  # its own — while this log shares its volume with the recordings. Time, not
  # a drop count, is what has to bound the log rate: a counter limiter emits
  # once per burst, and bursts are attacker-sized.
  @drop_log_interval_ms 5_000
  @id_preview 64

  defstruct group: nil,
            config: nil,
            routes: %{},
            port: nil,
            os_pid: nil,
            backoff_ms: nil,
            skipping_long_line: false,
            drops: %{},
            last_drop_log_ms: nil,
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

      {:ok, %{"camera_id" => _id, "pts" => _pts, "dets" => dets}} when is_list(dets) ->
        note_drops(state, 1, :non_numeric_pts)

      {:ok, _other} ->
        note_drops(state, 1, :missing_fields)

      {:error, _} ->
        note_drops(state, 1, :malformed_line)
    end
  end

  defp route(state, camera_id, pts, dets) do
    case Map.fetch(state.routes, camera_id) do
      {:ok, {cam, windows}} ->
        forward(state, cam, windows, pts, dets)

      :error ->
        note_drops(state, 1, :unknown_camera, preview(camera_id))
    end
  end

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

  # `camera_id` is plugin-supplied and can be any JSON value up to the line
  # limit. `inspect/2` escapes control bytes (no forged log lines) and
  # `printable_limit` bounds a binary by *bytes* — `String.slice/3` would not,
  # since one grapheme cluster can be arbitrarily long.
  defp preview(camera_id), do: inspect(camera_id, limit: 3, printable_limit: @id_preview)

  defp forward(state, cam, windows, pts, dets) do
    {dets, invalid} = PluginProtocol.validate_dets(dets)

    aggregator = Keyword.get(state.opts, :aggregator, Cairn.DetectionAggregator)
    Cairn.DetectionAggregator.detections(aggregator, cam, windows, pts, dets)

    note_drops(state, invalid, :invalid_det)
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
