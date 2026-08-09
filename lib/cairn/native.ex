defmodule Cairn.Native do
  @moduledoc """
  The `cairn-native` NIF binding: decode → motion gate → infer → Re-ID. All four
  entry points block, on a dirty scheduler.

  `config` and `params` must carry every key of the crate's `RawInitConfig` /
  `RawStreamParams`; build them with `Cairn.Native.Config`, never by hand.

  A missing library is a normal state, not a boot failure, so `load_nif/0`
  records why the load failed and still returns `:ok`: an `@on_load` returning
  anything else discards the module, and then every call to it — `available?/0`
  included — raises `undef`.

  The library is looked for at `priv/native/libcairn_native`, overridable via
  `config :cairn, Cairn.Native, path: ...`. Copying the cargo artifact there is
  not wired into `mix compile` yet.
  """

  @on_load :load_nif

  @load_result {__MODULE__, :load_result}

  @doc false
  def load_nif do
    :persistent_term.put(@load_result, load())
    :ok
  end

  @doc "True when the four NIFs below are the real ones."
  @spec available?() :: boolean()
  def available?, do: load_result() == :ok

  @doc "Why the library did not load, or `nil` when it did."
  @spec load_error() :: term() | nil
  def load_error do
    case load_result() do
      :ok -> nil
      {:error, reason} -> reason
    end
  end

  # `nif_error/1` has no return, so dialyzer flags every *static* call to a stub;
  # `Cairn.Native.Host` calls through a module held in its state, which keeps them
  # dynamic. The nowarn covers the specs, which describe the loaded library.
  @dialyzer {:nowarn_function, init: 1, open_stream: 3, push_au: 4, close_stream: 1}

  @spec init(map()) :: {:ok, reference()} | {:error, {atom(), String.t()}}
  def init(_config), do: :erlang.nif_error(:nif_not_loaded)

  @spec open_stream(reference(), String.t(), map()) ::
          {:ok, reference()} | {:error, {atom(), String.t()}}
  def open_stream(_engine, _camera_id, _params), do: :erlang.nif_error(:nif_not_loaded)

  @spec push_au(reference(), binary(), integer(), {integer(), integer()}) ::
          {:ok, {[map()], [String.t()]}} | {:error, {atom(), String.t()}}
  def push_au(_stream, _au, _pts, _time_base), do: :erlang.nif_error(:nif_not_loaded)

  @spec close_stream(reference()) :: {:ok, boolean()} | {:error, {atom(), String.t()}}
  def close_stream(_stream), do: :erlang.nif_error(:nif_not_loaded)

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
    case Application.get_env(:cairn, __MODULE__, [])[:path] do
      nil -> priv_path()
      path -> {:ok, String.to_charlist(path)}
    end
  end

  defp priv_path do
    case :code.priv_dir(:cairn) do
      {:error, reason} -> {:error, {:no_priv_dir, reason}}
      dir -> {:ok, :filename.join(dir, ~c"native/libcairn_native")}
    end
  end
end
