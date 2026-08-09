defmodule Cairn.NativeStub do
  @moduledoc """
  Stands in for `Cairn.Native` — the NIF boundary, which CI has no library for.

  Driven by the control map a test puts in `:persistent_term` under
  `{:native_stub, :control}`: `:test` is the pid every call reports to, and one
  key per function is what that function answers (a `push_au` or `close_stream`
  value may be a function of that arity, so a test can block, sleep or fail
  inside the call).
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
      # a call the model ran on, which is the only kind the health check counts
      nil -> {:ok, {[frame()], []}}
      result -> result
    end
  end

  @impl true
  def close_stream(stream) do
    # Before the control value, so that a close a test blocks inside is still
    # observable as having been called.
    notify({:close_stream, stream})

    case control(:close_stream, nil) do
      fun when is_function(fun, 1) -> fun.(stream)
      nil -> {:ok, true}
      result -> result
    end
  end

  @doc "The key every stub here reads its answers out of."
  def control, do: @control

  @doc """
  One frame of the shape `push_au/4` answers with.

  `inferred: false` is the frame the motion gate replayed without running the
  model, and no frame at all is the sampler not being due — the two returns
  `Cairn.Native.Host` must not count as inferences.
  """
  def frame(inferred \\ true), do: %{pts: 0, observed_at_ms: 0, inferred: inferred, objects: []}

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
