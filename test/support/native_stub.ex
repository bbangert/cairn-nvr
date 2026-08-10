defmodule Cairn.NativeStub do
  @moduledoc """
  Stands in for `Cairn.Native` — the NIF boundary, which CI has no library for.

  Driven by the control map a test puts in `:persistent_term` under
  `{:native_stub, :control}`: `:test` is the pid every call reports to, and one
  key per function is what that function answers (every key but `available?` and
  `init` may be a function of that function's arity, so a test can block, sleep
  or fail inside the call — `open_stream` is how a test blocks the host itself,
  since that one is called from the host process).
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

    case control(:open_stream, nil) do
      fun when is_function(fun, 3) -> fun.(engine, camera_id, params)
      nil -> {:ok, {:stream, camera_id}}
      result -> result
    end
  end

  @impl true
  def push_au(stream, au, pts, time_base) do
    started = System.monotonic_time(:microsecond)

    result =
      case control(:push_au, nil) do
        fun when is_function(fun, 4) -> fun.(stream, au, pts, time_base)
        # a call the model ran on, which is the only kind the health check counts
        nil -> {:ok, {[frame()], []}}
        result -> result
      end

    timed(result, System.monotonic_time(:microsecond) - started)
  end

  @impl true
  def cpu_baseline_ms(config, passes) do
    notify({:cpu_baseline_ms, config, passes})

    case control(:cpu_baseline_ms, nil) do
      fun when is_function(fun, 2) -> fun.(config, passes)
      # a plausible CPU p50 for a nano detector: what a real board measures here
      nil -> {:ok, 45.0}
      result -> result
    end
  end

  # The crate times the model pass alone; in the stub the whole call is that
  # pass, so a test sleeping to model a slow accelerator gets the sleep back.
  defp timed({:ok, {frames, ended_tracks}}, micros) do
    {:ok,
     {Enum.map(frames, &if(&1.inferred, do: %{&1 | infer_us: micros}, else: &1)), ended_tracks}}
  end

  defp timed(other, _micros), do: other

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
  def frame(inferred \\ true),
    do: %{pts: 0, observed_at_ms: 0, inferred: inferred, infer_us: 0, objects: []}

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
