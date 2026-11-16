defmodule Cairn.Rockchip.Native do
  @moduledoc """
  The Rockchip board's one NIF library.

  A missing library is a normal state, not a boot failure: this module loads
  `priv/native/libcairn_rockchip`, overridable via `config :cairn_rockchip,
  Cairn.Rockchip.Native, path: ...`, and `load_error/0` says why it did not.
  """

  @on_load :load_nif

  @load_result {__MODULE__, :load_result}

  @doc false
  def load_nif do
    :persistent_term.put(@load_result, load())
    :ok
  end

  @doc "True when the library loaded."
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
