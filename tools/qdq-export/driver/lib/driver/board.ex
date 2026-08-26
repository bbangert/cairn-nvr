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
  defstruct [:host, :node, :cookie, :boot_id, qnn_sessions: 0]

  @typedoc "A connected session; `qnn_sessions` counts against the CDSP budget."
  @type t :: %__MODULE__{
          host: String.t(),
          node: node(),
          cookie: atom(),
          boot_id: String.t(),
          qnn_sessions: non_neg_integer()
        }

  @doc "Enable distribution over ssh, connect, and monitor the node."
  @spec connect(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def connect(_host, _opts \\ []), do: raise("P1-T2")

  @doc "Return the session if its node is alive, else reconnect (re-enable + fresh cookie)."
  @spec ensure_session(t()) :: {:ok, t()} | {:error, term()}
  def ensure_session(%__MODULE__{} = _session), do: raise("P1-T2")

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
  def boot_id(%__MODULE__{} = _session), do: raise("P1-T3")

  @doc "Reboot: observe nodedown, wait for a changed boot id, re-enable, reconnect."
  @spec reboot(t()) :: {:ok, t()} | {:error, term()}
  def reboot(%__MODULE__{} = _session), do: raise("P1-T4")
end
