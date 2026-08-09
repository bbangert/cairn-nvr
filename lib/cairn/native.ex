defmodule Cairn.Native do
  @moduledoc """
  The `cairn-native` NIF binding: decode → motion gate → infer → Re-ID, running
  on this VM's dirty schedulers. All four entry points block, and are documented
  in `plugins/cairn-native/src/lib.rs`.

  `config` and `params` must carry *every* key of the crate's `RawInitConfig` /
  `RawStreamParams` — rustler refuses a map with one missing rather than
  defaulting it. `Cairn.Native.Config` is what fills them in; nothing should
  call these functions with a hand-built map.

  ## When the library is not there

  The cdylib is built by cargo, and neither the Elixir CI job nor a dev machine
  that has not run cargo has one, so a missing library is a normal state rather
  than a boot failure: `load_nif/0` records why the load failed and still returns
  `:ok`, which is what keeps the module loaded — an `@on_load` that returns
  anything else discards the module, and every call to it, `available?/0`
  included, raises `undef`. The stubs below raise `:nif_not_loaded` if anyone
  calls them anyway; `Cairn.Native.Host` checks `available?/0` first.

  The library is looked for at `priv/native/libcairn_native` (override with
  `config :cairn, Cairn.Native, path: "/some/libcairn_native"`, without the
  extension — the BEAM appends the platform's). Copying the cargo artifact
  there is not wired into `mix compile` yet.
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

  # `nif_error/1` has no return, which makes every stub `no_return` to dialyzer and
  # every *static* call to one an error it would report; `Cairn.Native.Host`
  # reaches them through a module held in its state for the test seam, which
  # happens to keep the calls dynamic and dialyzer quiet. The nowarn is for the
  # specs, which describe the loaded library and not the stub.
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
