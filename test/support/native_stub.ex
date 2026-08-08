defmodule Cairn.NativeStub do
  @moduledoc """
  Stands in for `Cairn.Native` — the NIF boundary, which CI has no library for.

  Driven by the control map a test puts in `:persistent_term` under
  `{:native_stub, :control}`: `:test` is the pid every call reports to, and one
  key per function is what that function answers (a `push_au` value may be a
  4-arity function, so a test can block, sleep or fail inside the call).
  """

  @behaviour Cairn.Native.Engine

  @control {:native_stub, :control}

  @impl true
  def available?, do: control(:available?, true)

  @impl true
  def load_error, do: if(available?(), do: nil, else: {:load_failed, ~c"no such file"})

  @impl true
  def init(config) do
    notify({:init, config})
    control(:init, {:ok, {:engine, config.model}})
  end

  @impl true
  def open_stream(engine, camera_id, params) do
    notify({:open_stream, engine, camera_id, params})
    control(:open_stream, {:ok, {:stream, camera_id}})
  end

  @impl true
  def push_au(stream, au, pts, time_base) do
    case control(:push_au, nil) do
      fun when is_function(fun, 4) -> fun.(stream, au, pts, time_base)
      nil -> {:ok, {[], []}}
      result -> result
    end
  end

  @impl true
  def close_stream(stream) do
    notify({:close_stream, stream})
    {:ok, true}
  end

  @doc "The key every stub here reads its answers out of."
  def control, do: @control

  defp notify(message) do
    case control(:test, nil) do
      nil -> :ok
      pid -> send(pid, message)
    end
  end

  defp control(key, default) do
    @control |> :persistent_term.get(%{}) |> Map.get(key, default)
  end
end
