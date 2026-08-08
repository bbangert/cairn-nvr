defmodule Cairn.Native.Canary do
  @moduledoc """
  Probe-load a model in a throwaway OS process, before the in-VM NIF opens it.

  Model load is the known NPU crash/wedge vector (D-M3's risk row; spike 0.5
  reproduced nothing in 83k steady-state inferences precisely because that
  vector lives in loading, not inference). In-VM a crash there is the whole
  node, so the load is rehearsed somewhere its death costs nothing first.

  `cairn-detect` links the same `cairn-detect` library the NIF does and opens
  the model through the same `Detector::open`, so running the binary *is* the
  same load.

  ## What it runs, and why that shape

  There is no load-and-exit mode in the binary. The probe is therefore group
  mode — `--cameras-json` with one synthetic member — because `run_multiplexed`
  writes a `plugin.status` `ready` line on stdout the moment the detector and
  the embedder are open, *before* it touches a socket, and because a member that
  never receives a packet is normal there rather than fatal (single-camera mode
  emits its `ready` only after the RTP stream opens, which never happens here).
  That line is the pass. The member's `udp_port` is required by the argument's
  own schema and is otherwise meaningless here: nothing binds it until after the
  line this waits for, and the process is killed the moment that line arrives —
  so it is 0 rather than a port allocated out of `Cairn.UDPPorts`, and a member
  thread that does reach a bind and fails only logs.

  A failure is whatever the process said on the way out: it exits non-zero with
  `fatal: …` on stderr for a model that will not open, which is the message the
  operator needs and `Cairn.Native.Host` refuses to load anything on.
  """

  alias Cairn.Native.Config

  @member "__canary__"
  @max_line 65_536
  @timeout_ms 120_000
  # How long a probe gets to honour a SIGTERM before it is killed outright. Only
  # a probe that is ignoring the signal ever waits it out: one that goes is
  # confirmed gone by its own `:exit_status`.
  @kill_grace_ms 1_000
  # Enough of the process's own output to explain a failure. It is stderr and
  # stdout interleaved, and the useful part is always the tail.
  @tail_lines 20

  @type result :: :ok | {:skipped, atom()} | {:error, String.t()}

  @doc """
  Options:

    * `:enabled` — `false` skips the probe outright (tests, and an operator who
      has other reasons to trust the model).
    * `:binary` — path to `cairn-detect`. Falls back to
      `config :cairn, Cairn.Native.Canary, binary: …` and then to `cairn-detect`
      on `PATH`. Absent everywhere, the probe is skipped: an installation
      without the plugin binary is a supported one and refusing to start there
      would be worse than not rehearsing.
    * `:timeout_ms` — a QNN HTP graph compile is multiple seconds and a cold
      one can be tens; the default is #{@timeout_ms} ms.
  """
  @spec probe(Config.t(), keyword()) :: result()
  def probe(config, opts \\ []) do
    cond do
      Keyword.get(opts, :enabled, true) == false -> {:skipped, :disabled}
      binary = binary(opts) -> run(binary, config, opts)
      true -> {:skipped, :no_binary}
    end
  end

  defp binary(opts) do
    path =
      Keyword.get(opts, :binary) ||
        Application.get_env(:cairn, __MODULE__, [])[:binary] ||
        System.find_executable("cairn-detect")

    if is_binary(path) and File.exists?(path), do: path
  end

  # The port belongs to a linked process that traps exits *before* it opens
  # anything, so a caller killed outright — the host, mid-canary — reaches the
  # probe as a signal something can still act on, rather than as a closed pipe
  # and an OS process left holding the model and the NPU. A port the caller owned
  # would have that hole for as long as it took to arrange any cleanup; here
  # there is nothing to orphan until after the flag is set.
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

    result =
      try do
        port =
          Port.open({:spawn_executable, binary}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            {:line, @max_line},
            args: argv
          ])

        await(port, System.monotonic_time(:millisecond) + timeout_ms, [])
      rescue
        error -> {:error, "could not run #{binary}: #{Exception.message(error)}"}
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
      # host GenServer, so that signal queues behind this receive and would
      # otherwise wait out the whole timeout with a probe holding the NPU. It is
      # put back rather than consumed — ending the caller is its own job, not
      # this function's.
      {:EXIT, _pid, _reason} = signal ->
        send(self(), signal)
        Process.exit(probe, :shutdown)
        stopped(monitor)
        {:error, "the probe load was cut short: its caller is exiting"}
    end
  end

  # Bounded: the probe's teardown escalates on its own (`stop/1`), and a caller
  # already shutting down must not be held here for longer than that takes.
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

      # A line past @max_line is not a status line; it is some stage's very long
      # diagnostic, and only the fact that the process is still talking matters.
      {^port, {:data, {:noeol, _partial}}} ->
        await(port, deadline, tail)

      {^port, {:exit_status, status}} ->
        {:error, "the probe load exited with status #{status}: #{explain(tail)}"}

      # This process owns the port and traps exits, so the port's own close
      # arrives here as a signal too. It is not the caller going away:
      # `:exit_status` above ends the wait, and the timeout below if that never
      # comes.
      {:EXIT, ^port, _reason} ->
        await(port, deadline, tail)

      # The caller is gone (this process is linked to it) or is telling this to
      # stop on its way out. Either way the probe does not outlive it.
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

  # `Port.close/1` closes the pipes and leaves the OS process running — the
  # plugin only ends its stdin reader thread on EOF — so the pid is signalled
  # first, exactly as `Cairn.FFmpegPort.kill_port/1` does. It escalates because
  # the probe is rehearsing the one operation known to wedge: a process stuck in
  # a native model load does not reach a signal handler, and an escaped probe
  # holds the model and the NPU against the next attempt.
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

  # The port's own `:exit_status` is the process being gone, which is what has
  # to be true before the polite signal is taken to have worked.
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
