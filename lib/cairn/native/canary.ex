defmodule Cairn.Native.Canary do
  @moduledoc """
  Probe-load a model in a throwaway OS process, before the in-VM NIF opens it.

  Model load is the known NPU crash/wedge vector (D-M3's risk row), and in-VM a
  crash there is the whole node. `cairn-detect` links the same library the NIF
  does and opens the model through the same `Detector::open`, so running the
  binary is the same load.

  The binary has no load-and-exit mode, so the probe runs `group` mode
  (`--cameras-json` with one synthetic member): `run_multiplexed` writes its
  `ready` line the moment the detector and embedder are open, before it touches a
  socket, and a member that never receives a packet is normal there. Single-camera
  mode's `ready` line waits on the RTP stream opening, which never happens here,
  so it would hang. `udp_port` is `0` because the schema requires the key and
  nothing binds it.

  A missing binary is a failure and not a skip: a packaging or `PATH` mistake must
  refuse the load rather than quietly perform it unrehearsed. Loading without a
  probe stays possible, but only when asked for (`enabled: false`).
  """

  alias Cairn.Native.Config

  @member "__canary__"
  @max_line 65_536
  @timeout_ms 120_000
  # How long a probe gets to honour a SIGTERM before it is killed outright.
  @kill_grace_ms 1_000
  # Enough of the tail (stdout and stderr interleaved) to explain a failure.
  @tail_lines 20

  @type result :: :ok | {:skipped, :disabled} | {:error, String.t()}

  # `@behaviour` on this module too, so a stub that stops answering the host's
  # `:canary_module` seam fails at compile time rather than in whatever test
  # reaches for it next.
  @callback probe(Config.t(), keyword()) :: result()
  @behaviour __MODULE__

  @doc """
  Options:

    * `:enabled` — `false` skips the probe outright, the only way to load a model
      that was never rehearsed.
    * `:binary` — path to `cairn-detect`. Falls back to
      `config :cairn, Cairn.Native.Canary, binary: …` and then to `cairn-detect`
      on `PATH`. Absent everywhere is an error, not a skip.
    * `:timeout_ms` — a QNN HTP graph compile is multiple seconds and a cold
      one can be tens; the default is #{@timeout_ms} ms.
  """
  @spec probe(Config.t(), keyword()) :: result()
  def probe(config, opts \\ []) do
    cond do
      Keyword.get(opts, :enabled, true) == false -> {:skipped, :disabled}
      binary = binary(opts) -> run(binary, config, opts)
      true -> {:error, no_binary(opts)}
    end
  end

  defp binary(opts) do
    path = configured(opts)
    if is_binary(path) and File.exists?(path), do: path
  end

  # First path named wins even if it is not there, rather than falling through to
  # `PATH`: probing a different binary would rehearse the wrong load.
  defp configured(opts) do
    Keyword.get(opts, :binary) ||
      Application.get_env(:cairn, __MODULE__, [])[:binary] ||
      System.find_executable("cairn-detect")
  end

  defp no_binary(opts) do
    tried = configured(opts) || "cairn-detect (nowhere on PATH)"

    "the probe load cannot run: no cairn-detect binary at #{tried}. Install it, or point " <>
      "`config :cairn, Cairn.Native.Canary, binary: \"/path/to/cairn-detect\"` at it. Setting " <>
      "`enabled: false` there loads the model in this VM with no rehearsal, which is a crash " <>
      "of the whole node if it goes wrong"
  end

  # The port belongs to a linked process that traps exits before it opens anything,
  # so a caller killed outright — the host, mid-canary — reaches the probe as a
  # signal, not as a closed pipe and an OS process still holding the NPU.
  defp run(binary, config, opts) do
    member = Jason.encode!([%{id: @member, udp_port: 0}])
    argv = Config.to_argv(config) ++ ["--cameras-json", member]
    timeout_ms = Keyword.get(opts, :timeout_ms, @timeout_ms)
    caller = self()
    ref = make_ref()

    probe = spawn_link(fn -> probe_port(caller, ref, binary, argv, timeout_ms) end)
    collect(probe, Process.monitor(probe), ref)
  end

  defp probe_port(caller, ref, binary, argv, timeout_ms) do
    Process.flag(:trap_exit, true)

    # The rescue covers Port.open alone: "could not run" must mean exactly
    # that. Wrapping await/stop too once relabeled a teardown failure (no
    # `kill` binary in the image) as a failed run — of a probe whose model
    # load had SUCCEEDED on the HTP. A raise past open crashes this process
    # and reaches the caller as "ended without answering: <reason>".
    result =
      try do
        {:ok,
         Port.open({:spawn_executable, binary}, [
           :binary,
           :exit_status,
           :stderr_to_stdout,
           {:line, @max_line},
           args: argv
         ])}
      rescue
        error -> {:error, "could not run #{binary}: #{Exception.message(error)}"}
      end

    result =
      case result do
        {:ok, port} -> await(port, System.monotonic_time(:millisecond) + timeout_ms, [])
        {:error, _message} = error -> error
      end

    send(caller, {ref, result})
  end

  defp collect(probe, monitor, ref) do
    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, _pid, reason} ->
        {:error, "the probe load ended without answering: #{inspect(reason)}"}

      # The linked probe finishing is not the caller going away: it answers on
      # `ref`, and this is only the link telling us it is done.
      {:EXIT, ^probe, _reason} ->
        collect(probe, monitor, ref)

      # Anything else is the caller being shut down. `probe/2` runs inline in the
      # host GenServer, so that signal would otherwise wait out the whole timeout
      # with a probe holding the NPU. Put back, not consumed: ending the caller is
      # not this function's job.
      {:EXIT, _pid, _reason} = signal ->
        send(self(), signal)
        Process.exit(probe, :shutdown)
        stopped(monitor)
        {:error, "the probe load was cut short: its caller is exiting"}
    end
  end

  # Bounded, because `stop/1` escalates on its own and a caller already shutting
  # down must not be held here for longer than that takes.
  defp stopped(monitor) do
    receive do
      {:DOWN, ^monitor, :process, _pid, _reason} -> :ok
    after
      @kill_grace_ms * 2 -> :ok
    end
  end

  defp await(port, deadline, tail) do
    wait = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, {:eol, line}}} ->
        if ready?(line) do
          stop(port)
          :ok
        else
          await(port, deadline, Enum.take([line | tail], @tail_lines))
        end

      # A line past @max_line is not a status line; only the fact that the process
      # is still talking matters.
      {^port, {:data, {:noeol, _partial}}} ->
        await(port, deadline, tail)

      {^port, {:exit_status, status}} ->
        {:error, "the probe load exited with status #{status}: #{explain(tail)}"}

      # The port's own close, not the caller going away.
      {:EXIT, ^port, _reason} ->
        await(port, deadline, tail)

      # The caller is gone, or is telling this to stop on its way out. Either way
      # the probe does not outlive it.
      {:EXIT, _pid, _reason} ->
        stop(port)
        {:error, "the probe load was cut short: its caller is exiting"}
    after
      wait ->
        stop(port)
        {:error, "the probe load did not open the model within the timeout: #{explain(tail)}"}
    end
  end

  defp ready?(line) do
    match?(
      {:ok,
       %{"spec" => "cairn.plugin", "type" => "plugin.status", "status" => %{"state" => "ready"}}},
      Jason.decode(line)
    )
  end

  defp explain([]), do: "it said nothing"
  defp explain(tail), do: tail |> Enum.reverse() |> Enum.join(" | ")

  # `Port.close/1` closes the pipes and leaves the OS process running, so the pid is
  # signalled first, as `Cairn.FFmpegPort.kill_port/1` does. It escalates to KILL
  # because a process stuck in a native model load never reaches a signal handler,
  # and an escaped probe holds the NPU against the next attempt.
  defp stop(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        signal(os_pid, "TERM")
        unless exited?(port, @kill_grace_ms), do: signal(os_pid, "KILL")

      nil ->
        :ok
    end

    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end
  end

  defp exited?(port, grace_ms) do
    receive do
      {^port, {:exit_status, _status}} -> true
    after
      grace_ms -> false
    end
  end

  defp signal(os_pid, name) do
    System.cmd("kill", ["-#{name}", Integer.to_string(os_pid)], stderr_to_stdout: true)
    :ok
  end
end
