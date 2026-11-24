defmodule Cairn.Rockchip.Native do
  @moduledoc """
  The Rockchip board's one NIF library: the RKNN engine, on `CairnOrt`'s
  engine surface (no `cpu_baseline_ms`: the host measures the baseline in a
  subprocess), and the MPP decoder on `Cairn.Stage.DecoderNif`, whose
  frames are leases on RGA-scaled dma-buf slots that `download/1` reads and
  `release/1` gives back.

  A missing library is a normal state, not a boot failure: this module loads
  `priv/native/libcairn_rockchip`, overridable via `config :cairn_rockchip,
  Cairn.Rockchip.Native, path: ...`, and `load_error/0` says why it did not.
  """

  # Also a `Cairn.Stage.DecoderNif`, undeclared: the two behaviours share
  # `available?/0`, `load_error/0` and `drain_teardown/1`, which the compiler
  # reports as conflicting. The suite checks the decoder half instead.
  @behaviour Cairn.Stage.EngineNif

  @on_load :load_nif

  @load_result {__MODULE__, :load_result}

  @doc false
  def load_nif do
    :persistent_term.put(@load_result, load())
    :ok
  end

  @doc "True when the library loaded."
  @impl true
  @spec available?() :: boolean()
  def available?, do: load_result() == :ok

  @doc "Why the library did not load, or `nil` when it did."
  @impl true
  @spec load_error() :: term() | nil
  def load_error do
    case load_result() do
      :ok -> nil
      {:error, reason} -> reason
    end
  end

  # `nif_error/1` has no return, so dialyzer flags every static call to a stub;
  # the host calls through a module held in its state. The nowarn covers the
  # specs, which describe the loaded library.
  @dialyzer {:nowarn_function,
             init: 1,
             init: 2,
             engine_spec: 1,
             open_stream: 3,
             push_frame: 4,
             close_stream: 1,
             open_decoder: 2,
             decode_au: 4,
             close_decoder: 1,
             download: 1,
             release: 1,
             drain_teardown: 1,
             contract: 0,
             frame_meta_keys: 0}

  # The library path rides the call because the NIF cannot read the VM's
  # environment: `System.put_env/2` writes the BEAM's own copy, which libc's
  # `getenv` never sees.
  @impl true
  def init(config), do: init(config, System.get_env("CAIRN_RKNN_LIBRARY"))

  @doc false
  @spec init(map(), String.t() | nil) :: {:ok, reference()} | {:error, {atom(), String.t()}}
  def init(_config, _library), do: :erlang.nif_error(:nif_not_loaded)

  @impl true
  def engine_spec(_engine), do: :erlang.nif_error(:nif_not_loaded)

  @impl true
  def open_stream(_engine, _stream_id, _params), do: :erlang.nif_error(:nif_not_loaded)

  @impl true
  def push_frame(_stream, _payload, _meta, _time_base), do: :erlang.nif_error(:nif_not_loaded)

  @impl true
  def close_stream(_stream), do: :erlang.nif_error(:nif_not_loaded)

  @spec open_decoder(String.t(), map()) :: {:ok, reference()} | {:error, {atom(), String.t()}}
  def open_decoder(_camera_id, _params), do: :erlang.nif_error(:nif_not_loaded)

  @spec decode_au(reference(), binary(), integer(), boolean()) ::
          {:ok, {boolean(), Cairn.Stage.DecoderNif.lease_frame() | nil}}
          | {:error, {atom(), String.t()}}
  def decode_au(_decoder, _au, _pts, _sample), do: :erlang.nif_error(:nif_not_loaded)

  @spec close_decoder(reference()) :: {:ok, boolean()} | {:error, {atom(), String.t()}}
  def close_decoder(_decoder), do: :erlang.nif_error(:nif_not_loaded)

  # On a dirty CPU scheduler: a frame-sized copy out of the slot.
  @spec download(reference()) :: {:ok, binary()} | {:error, {atom(), String.t()}}
  def download(_lease), do: :erlang.nif_error(:nif_not_loaded)

  # Idempotent. On a dirty I/O scheduler: a release racing a download waits
  # out its copy.
  @spec release(reference()) :: :ok
  def release(_lease), do: :erlang.nif_error(:nif_not_loaded)

  # This library's own teardown queue: `CairnOrt`'s drain does not reach it.
  @impl true
  def drain_teardown(_timeout_ms), do: :erlang.nif_error(:nif_not_loaded)

  # `cairn_ort::CONTRACT` as this library was built: the engine half is that
  # crate's, so the number is too.
  @impl true
  def contract, do: :erlang.nif_error(:nif_not_loaded)

  @impl true
  def frame_meta_keys, do: :erlang.nif_error(:nif_not_loaded)

  defp load_result, do: :persistent_term.get(@load_result, {:error, :not_loaded})

  defp load do
    case so_path() do
      {:ok, path} -> :erlang.load_nif(path, 0)
      {:error, _reason} = error -> error
    end
  end

  # No existence check before the load: the BEAM owns the platform's library
  # suffix, so the only reliable way to ask whether the file is there is to try.
  defp so_path do
    case Application.get_env(:cairn_rockchip, __MODULE__, [])[:path] do
      nil -> priv_path()
      path -> {:ok, String.to_charlist(path)}
    end
  end

  defp priv_path do
    case :code.priv_dir(:cairn_rockchip) do
      {:error, reason} -> {:error, {:no_priv_dir, reason}}
      dir -> {:ok, :filename.join(dir, ~c"native/libcairn_rockchip")}
    end
  end
end
