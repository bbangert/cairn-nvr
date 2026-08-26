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
  @erpc_timeout 15_000
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

  @doc "Run a shell command on the board; returns `{output, exit_status}` for real."
  @spec cmd(t(), String.t(), keyword()) :: {String.t(), non_neg_integer()}
  def cmd(%__MODULE__{} = _session, _sh, _opts \\ []), do: raise("P1-T3")

  @doc "Read a board file whole-or-error."
  @spec read!(t(), Path.t()) :: binary()
  def read!(%__MODULE__{} = _session, _path), do: raise("P1-T3")

  @doc "Write a local file to the board, chunked, sha-verified board-side."
  @spec write!(t(), Path.t(), Path.t()) :: :ok
  def write!(%__MODULE__{} = _session, _local, _remote), do: raise("P1-T3")

  @doc "The board's current boot id — the witness that a reboot happened."
  @spec boot_id(t()) :: String.t()
  def boot_id(%__MODULE__{node: node}) do
    :erpc.call(node, File, :read!, [@boot_id_path], @erpc_timeout) |> String.trim()
  end

  @doc "Reboot: observe nodedown, wait for a changed boot id, re-enable, reconnect."
  @spec reboot(t()) :: {:ok, t()} | {:error, term()}
  def reboot(%__MODULE__{} = _session), do: raise("P1-T4")

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
