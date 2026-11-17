defmodule Cairn.Rockchip.Native do
  @moduledoc """
  The Rockchip board's one NIF library: the RKNN engine, on `CairnOrt`'s
  engine surface (no `cpu_baseline_ms`: the host measures the baseline in a
  subprocess).

  A missing library is a normal state, not a boot failure: this module loads
  `priv/native/libcairn_rockchip`, overridable via `config :cairn_rockchip,
  Cairn.Rockchip.Native, path: ...`, and `load_error/0` says why it did not.
  """

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
             engine_spec: 1,
             open_stream: 3,
             push_frame: 4,
             close_stream: 1,
             drain_teardown: 1}

  @impl true
  def init(_config), do: :erlang.nif_error(:nif_not_loaded)

  @impl true
  def engine_spec(_engine), do: :erlang.nif_error(:nif_not_loaded)

  @impl true
  def open_stream(_engine, _stream_id, _params), do: :erlang.nif_error(:nif_not_loaded)

  @impl true
  def push_frame(_stream, _payload, _meta, _time_base), do: :erlang.nif_error(:nif_not_loaded)

  @impl true
  def close_stream(_stream), do: :erlang.nif_error(:nif_not_loaded)

  # This library's own teardown queue: `CairnOrt`'s drain does not reach it.
  @impl true
  def drain_teardown(_timeout_ms), do: :erlang.nif_error(:nif_not_loaded)

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
