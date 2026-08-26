defmodule Driver.Board do
  @moduledoc """
  Board session over Erlang distribution: bring-up via `Vagus.Dist.enable()`
  (the one remaining ssh exec), then everything through `:erpc` — real
  exit codes as terms, whole-or-error reads.

  Distribution is enable-per-boot with a fresh cookie each session, and a
  reboot is the only off switch — so every campaign reboot (CDSP budget)
  kills the session. Stages call `ensure_session/1` rather than assuming
  a live node.
  """

  @enforce_keys [:host, :node, :cookie, :boot_id]
  defstruct [:host, :node, :cookie, :boot_id, ssh: Driver.Board.Ssh.Cmd, qnn_sessions: 0]

  @typedoc "A connected session; `qnn_sessions` counts against the CDSP budget."
  @type t :: %__MODULE__{
          host: String.t(),
          node: node(),
          cookie: atom(),
          boot_id: String.t(),
          ssh: module(),
          qnn_sessions: non_neg_integer()
        }

  @boot_id_path "/proc/sys/kernel/random/boot_id"
  @gov_saved "/data/campaign-gov.saved"
  @gov_glob "/sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor"
  @erpc_timeout 15_000
  @cmd_timeout 30_000
  @chunk_bytes 4 * 1024 * 1024
  # A racing enable() settles in well under a second; three tries covers it.
  @starting_retries 3

  @doc """
  Enable distribution over ssh, connect, and monitor the node.

  `{:error, :node_gone}` is terminal for the session: the board holds a
  dist record without a live node and only a reboot clears it — never
  retried, never adopted.
  """
  @spec connect(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def connect(host, opts \\ []) do
    ssh = Keyword.get(opts, :ssh, Driver.Board.Ssh.Cmd)

    with {:ok, %{node: node, cookie: cookie}} <- enable(ssh, host, @starting_retries),
         :ok <- ensure_local_node(host),
         true <- Node.set_cookie(node, cookie),
         :ok <- :net_kernel.monitor_nodes(true),
         :ok <- try_connect(node, 3) do
      boot_id =
        :erpc.call(node, File, :read!, [@boot_id_path], @erpc_timeout) |> String.trim()

      {:ok, %__MODULE__{host: host, node: node, cookie: cookie, boot_id: boot_id, ssh: ssh}}
    end
  end

  @doc """
  Return the session if its node answers, else re-enable and reconnect.
  A same-boot reconnect keeps the QNN-session counter; a changed boot id
  means the CDSP started clean, so the counter resets.
  """
  @spec ensure_session(t()) :: {:ok, t()} | {:error, term()}
  def ensure_session(%__MODULE__{} = session) do
    if :net_adm.ping(session.node) == :pong do
      {:ok, session}
    else
      with {:ok, fresh} <- connect(session.host, ssh: session.ssh) do
        if fresh.boot_id == session.boot_id do
          {:ok, %{fresh | qnn_sessions: session.qnn_sessions}}
        else
          {:ok, fresh}
        end
      end
    end
  end

  @doc """
  Parse the ssh channel's `Vagus.Dist.enable()` output. The channel
  emits `\\r\\n`; an unstripped CR in the node name fails `Node.connect`
  with a bare `false`, so stripping happens here, once.
  """
  @spec parse_enable(String.t()) ::
          {:ok, %{node: node(), cookie: atom()}} | {:error, term()}
  def parse_enable(raw) do
    clean = String.replace(raw, "\r", "")

    cond do
      clean =~ "{:error, :starting}" ->
        {:error, :starting}

      clean =~ "{:error, :node_gone}" ->
        {:error, :node_gone}

      true ->
        # Node names and cookies are atoms by OTP contract, so creation is
        # unavoidable; the shape-pinned regexes bound it to two atoms per
        # session from our own board's output — not open-ended input.
        with [_, node] <- Regex.run(~r/node: :"(vagus@[0-9.]+)"/, clean),
             [_, cookie] <- Regex.run(~r/cookie: :?"([0-9a-f]{64})"/, clean) do
          {:ok, %{node: :erlang.binary_to_atom(node), cookie: :erlang.binary_to_atom(cookie)}}
        else
          nil -> {:error, {:unparseable_enable, clean}}
        end
    end
  end

  @doc """
  Run a shell command on the board; returns `{output, exit_status}` for
  real — the property the whole port exists for. Pipes are fine again:
  this is `System.cmd("sh", ["-c", ...])` on the board, not a `~c|...|`
  sigil. `:timeout` (ms, default #{@cmd_timeout}) raises on the caller
  without wedging the node.
  """
  @spec cmd(t(), String.t(), keyword()) :: {String.t(), non_neg_integer()}
  def cmd(%__MODULE__{node: node}, sh, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @cmd_timeout)
    :erpc.call(node, System, :cmd, ["sh", ["-c", sh], [stderr_to_stdout: true]], timeout)
  end

  @doc "Read a board file whole-or-error — no partial fetches by construction."
  @spec read!(t(), Path.t(), timeout()) :: binary()
  def read!(%__MODULE__{node: node}, path, timeout \\ @cmd_timeout) do
    :erpc.call(node, File, :read!, [path], timeout)
  end

  @doc """
  Write a local file to the board, chunked ≤4MB, sha-verified board-side.

  `async_dist` is set on the local caller for the duration: the pushing
  sender is THIS process, so the flag belongs here — `Vagus.Dist.run/1`
  is the board-side equivalent, and a local closure cannot cross `:erpc`
  to reach it anyway.
  """
  @spec write!(t(), Path.t(), Path.t()) :: :ok
  def write!(%__MODULE__{node: node} = session, local, remote) do
    content = File.read!(local)
    local_sha = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
    :ok = :erpc.call(node, File, :mkdir_p!, [Path.dirname(remote)], @cmd_timeout)

    prev = Process.flag(:async_dist, true)

    try do
      for {chunk, i} <- content |> chunk_binary(@chunk_bytes) |> Enum.with_index() do
        modes = if i == 0, do: [], else: [:append]
        :ok = :erpc.call(node, File, :write!, [remote, chunk, modes], @cmd_timeout)
      end
    after
      Process.flag(:async_dist, prev)
    end

    case cmd(session, "sha256sum #{remote}") do
      {out, 0} ->
        [board_sha | _] = String.split(out)

        if board_sha == local_sha,
          do: :ok,
          else: raise("push sha mismatch for #{remote}: #{board_sha} != #{local_sha}")

      {out, rc} ->
        raise "cannot sha-verify #{remote} (rc #{rc}): #{out}"
    end
  end

  @doc """
  Pin every CPU governor to `performance`, readback-verified; returns the
  pre-campaign governor. Capture-once semantics live board-side in
  #{@gov_saved} (`test ! -s`, not `-f`: a failed save leaves an EMPTY
  file, which must re-save rather than wedge), so re-entry never records
  the pin as the thing to restore.
  """
  @spec pin_governor(t()) :: {:ok, String.t()} | {:error, term()}
  def pin_governor(%__MODULE__{} = session) do
    save =
      "if test ! -s #{@gov_saved}; then " <>
        "cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor > #{@gov_saved}; fi; " <>
        "cat #{@gov_saved}"

    with {:save, {out, 0}} <- {:save, cmd(session, save)},
         saved = String.trim(out),
         {:saved_empty, false} <- {:saved_empty, saved == ""},
         {:pin, {_, 0}} <- {:pin, cmd(session, set_all_governors("performance"))},
         :ok <- verify_governors(session, "performance") do
      {:ok, saved}
    else
      {:save, {out, rc}} -> {:error, {:gov_save, rc, out}}
      {:saved_empty, true} -> {:error, :empty_saved_governor}
      {:pin, {out, rc}} -> {:error, {:gov_pin, rc, out}}
      {:error, _} = error -> error
    end
  end

  @doc """
  Restore ONLY what `pin_governor/1` captured — a finish reached without
  a pin restores nothing. The saved file is removed only after a
  readback verifies the restore took, so a failed restore stays
  restorable on the next finish.
  """
  @spec restore_governor(t()) ::
          {:ok, {:restored, String.t()} | :nothing_to_restore} | {:error, term()}
  def restore_governor(%__MODULE__{} = session) do
    case cmd(session, "test -e #{@gov_saved}") do
      {_, rc} when rc != 0 ->
        {:ok, :nothing_to_restore}

      {_, 0} ->
        with {:read, {out, 0}} <- {:read, cmd(session, "cat #{@gov_saved}")},
             saved = String.trim(out),
             {:saved_empty, false} <- {:saved_empty, saved == ""},
             {:set, {_, 0}} <- {:set, cmd(session, set_all_governors(saved))},
             :ok <- verify_governors(session, saved),
             {:rm, {_, 0}} <- {:rm, cmd(session, "rm -f #{@gov_saved}")} do
          {:ok, {:restored, saved}}
        else
          {:read, {out, rc}} -> {:error, {:gov_read, rc, out}}
          {:saved_empty, true} -> {:error, :empty_saved_governor}
          {:set, {out, rc}} -> {:error, {:gov_restore, rc, out}}
          {:rm, {out, rc}} -> {:error, {:gov_saved_rm, rc, out}}
          {:error, _} = error -> error
        end
    end
  end

  @doc """
  Container names from `balena-engine ps` — a failed ps is an error, not
  an empty list, so it can never read as "engine stopped".
  """
  @spec engine_state(t()) :: {:ok, [String.t()]} | {:error, term()}
  def engine_state(%__MODULE__{} = session) do
    case cmd(session, "balena-engine ps --format {{.Names}}") do
      {out, 0} -> {:ok, String.split(out, "\n", trim: true)}
      {out, rc} -> {:error, {:engine_ps, rc, out}}
    end
  end

  @doc """
  Stop a container and verify by state readback — the stop's own rc is
  ignored (already-stopped is fine), the readback is not.
  """
  @spec engine_stop(t(), String.t()) :: :ok | {:error, term()}
  def engine_stop(%__MODULE__{} = session, container) do
    {_out, _rc} = cmd(session, "balena-engine stop #{container}", timeout: 90_000)

    case engine_state(session) do
      {:ok, names} ->
        if container in names, do: {:error, {:container_still_running, container}}, else: :ok

      {:error, _} = error ->
        error
    end
  end

  @doc "Start a container and verify by state readback."
  @spec engine_start(t(), String.t()) :: :ok | {:error, term()}
  def engine_start(%__MODULE__{} = session, container) do
    with {:start, {_, 0}} <-
           {:start, cmd(session, "balena-engine start #{container}", timeout: 90_000)},
         {:ok, names} <- engine_state(session) do
      if container in names, do: :ok, else: {:error, {:container_not_running, container}}
    else
      {:start, {out, rc}} -> {:error, {:engine_start, rc, out}}
      {:error, _} = error -> error
    end
  end

  @doc "The board's current boot id — the witness that a reboot happened."
  @spec boot_id(t()) :: String.t()
  def boot_id(%__MODULE__{node: node}) do
    :erpc.call(node, File, :read!, [@boot_id_path], @erpc_timeout) |> String.trim()
  end

  @doc """
  Reboot the board and prove it happened: nodedown observed via the
  monitor, then a reconnect whose boot id CHANGED — a liveness probe
  alone would "succeed" immediately if the reboot command never ran and
  the board stayed up. The fresh session's `qnn_sessions` is 0: a new
  boot is what clears the CDSP leak, which is why campaigns reboot at
  all.

  Options (test hooks and pacing): `:reboot_cmd` (default `"reboot"`),
  `:nodedown_timeout` (60s), `:deadline` (300s), `:interval` (5s).
  """
  @spec reboot(t(), keyword()) :: {:ok, t()} | {:error, term()}
  def reboot(%__MODULE__{node: node} = session, opts \\ []) do
    nodedown_timeout = Keyword.get(opts, :nodedown_timeout, 60_000)
    deadline = Keyword.get(opts, :deadline, 300_000)
    interval = Keyword.get(opts, :interval, 5_000)
    reboot_cmd = Keyword.get(opts, :reboot_cmd, "reboot")

    :ok = :net_kernel.monitor_nodes(true)
    # cast, not call: the connection dies mid-command, so no reply comes.
    :ok = :erpc.cast(node, System, :cmd, ["sh", ["-c", reboot_cmd], []])

    receive do
      {:nodedown, ^node} ->
        reconnect_after_reboot(session, monotonic_ms() + deadline, interval)
    after
      nodedown_timeout -> {:error, :reboot_not_observed}
    end
  end

  defp enable(_ssh, _host, 0), do: {:error, :starting}

  defp enable(ssh, host, retries) do
    with {:ok, raw} <- ssh.enable(host),
         {:error, :starting} <- parse_enable(raw) do
      Process.sleep(1_000)
      enable(ssh, host, retries - 1)
    end
  end

  # The board end is longnames on a bare IP, so a fresh local node must
  # be too — named by the interface that routes to the board (Docker NAT
  # is outbound-only, which is all distribution needs). A node already
  # alive (tests) is used as-is.
  defp ensure_local_node(host) do
    if Node.alive?() do
      :ok
    else
      {_, 0} = System.cmd("epmd", ["-daemon"])
      {route, 0} = System.cmd("ip", ["route", "get", host])
      [_, src] = Regex.run(~r/src (\S+)/, route)

      case :net_kernel.start(:"driver@#{src}", %{name_domain: :longnames}) do
        {:ok, _pid} -> :ok
        {:error, reason} -> {:error, {:local_node, reason}}
      end
    end
  end

  defp reconnect_after_reboot(session, deadline_ms, interval) do
    case connect(session.host, ssh: session.ssh) do
      {:ok, fresh} when fresh.boot_id != session.boot_id ->
        {:ok, fresh}

      {:ok, _same_boot} ->
        # Node down and back with the SAME boot id: distribution bounced
        # without a reboot. Adopting it would fake a cleared CDSP.
        {:error, :boot_id_unchanged}

      {:error, :node_gone} ->
        {:error, :node_gone}

      {:error, _down_or_starting} ->
        if monotonic_ms() >= deadline_ms do
          {:error, :reboot_reconnect_deadline}
        else
          Process.sleep(interval)
          reconnect_after_reboot(session, deadline_ms, interval)
        end
    end
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp set_all_governors(governor) do
    "for c in /sys/devices/system/cpu/cpu[0-9]*; do echo #{governor} > $c/cpufreq/scaling_governor; done"
  end

  defp verify_governors(session, expected) do
    case cmd(session, "cat #{@gov_glob}") do
      {out, 0} ->
        governors = String.split(out, "\n", trim: true)

        if governors != [] and Enum.all?(governors, &(&1 == expected)),
          do: :ok,
          else: {:error, {:governor_readback, expected, governors}}

      {out, rc} ->
        {:error, {:governor_readback_failed, rc, out}}
    end
  end

  defp chunk_binary(bin, size) when byte_size(bin) <= size, do: [bin]

  defp chunk_binary(bin, size) do
    <<chunk::binary-size(^size), rest::binary>> = bin
    [chunk | chunk_binary(rest, size)]
  end

  defp try_connect(_node, 0), do: {:error, :connect_failed}

  defp try_connect(node, retries) do
    if Node.connect(node) == true do
      :ok
    else
      Process.sleep(500)
      try_connect(node, retries - 1)
    end
  end
end
