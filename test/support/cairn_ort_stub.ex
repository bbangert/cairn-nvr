defmodule Cairn.CairnOrtStub do
  @moduledoc """
  Stands in for `CairnOrt` — the inference NIF boundary, which CI has no
  library for. Reads the SAME control map as `Cairn.NativeStub` (the decode
  half), so one test setup drives the whole split boundary; the keys are this
  module's function names (`:init`, `:engine_spec`, `:open_stream`,
  `:push_frame`, `:close_stream`, `:cpu_baseline_ms`), plus `:ort_available?`
  so a test can take this library away while the decode one stays.
  """

  @behaviour CairnOrt.Engine

  alias Cairn.NativeStub

  @impl true
  def available?, do: control(:ort_available?, true)

  @impl true
  def load_error, do: if(available?(), do: nil, else: {:load_failed, ~c"no such file"})

  @impl true
  def init(config) do
    notify({:init, config})
    control(:init, {:ok, {:engine, config.model}})
  end

  # The default agrees with `NativeStub.decoded_frame/1`'s geometry: a 4x4
  # letterbox model rect whose 4x4-source frames scale to a 2x2 content rect.
  @impl true
  def engine_spec(engine) do
    notify({:engine_spec, engine})

    control(:engine_spec, %{
      width: 4,
      height: 4,
      encoding: "raw_bgr",
      resize: "letterbox",
      resize_pad: 114
    })
  end

  @impl true
  def open_stream(engine, stream_id, params) do
    notify({:open_stream, engine, stream_id, params})

    case control(:open_stream, nil) do
      fun when is_function(fun, 3) -> fun.(engine, stream_id, params)
      nil -> {:ok, {:stream, stream_id}}
      result -> result
    end
  end

  @impl true
  def push_frame(stream, payload, meta, time_base) do
    started = System.monotonic_time(:microsecond)

    result =
      case control(:push_frame, nil) do
        fun when is_function(fun, 4) -> fun.(stream, payload, meta, time_base)
        # a call the model ran on, which is the only kind the health check counts
        nil -> {:ok, {[NativeStub.frame()], []}}
        result -> result
      end

    timed(result, System.monotonic_time(:microsecond) - started)
  end

  # The crate times the model pass alone; in the stub the whole call is that
  # pass, so a test sleeping to model a slow accelerator gets the sleep back.
  defp timed({:ok, {frames, ended_tracks}}, micros) do
    {:ok,
     {Enum.map(frames, &if(&1.inferred, do: %{&1 | infer_us: micros}, else: &1)), ended_tracks}}
  end

  defp timed(other, _micros), do: other

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

  defp notify(message) do
    case control(:test, nil) do
      nil -> :ok
      pid -> send(pid, message)
    end
  end

  defp control(key, default) do
    NativeStub.control() |> :persistent_term.get(%{}) |> Map.get(key, default)
  end
end
