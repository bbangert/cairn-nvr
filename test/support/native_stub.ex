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
  def open_decoder(engine, camera_id, params) do
    notify({:open_decoder, engine, camera_id, params})

    case control(:open_decoder, nil) do
      fun when is_function(fun, 3) -> fun.(engine, camera_id, params)
      nil -> {:ok, {:decoder, camera_id}}
      result -> result
    end
  end

  @impl true
  def decode_au(decoder, au, pts, sample) do
    notify({:decode_au, decoder, au, pts, sample})

    case control(:decode_au, nil) do
      fun when is_function(fun, 4) -> fun.(decoder, au, pts, sample)
      # every access unit completes a frame, handed over when sampled — the
      # simplest decoder there is
      nil -> {:ok, {true, if(sample, do: decoded_frame(pts: pts), else: nil)}}
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

  @impl true
  def close_decoder(decoder) do
    notify({:close_decoder, decoder})

    case control(:close_decoder, nil) do
      fun when is_function(fun, 1) -> fun.(decoder)
      nil -> {:ok, true}
      result -> result
    end
  end

  @doc "The key every stub here reads its answers out of."
  def control, do: @control

  @doc """
  One frame of the shape `push_frame/4` answers with.

  `inferred: false` is the frame the motion gate replayed without running the
  model, and no frame at all is the sampler not being due — the two returns
  `Cairn.Native.Host` must not count as inferences.
  """
  def frame(inferred \\ true),
    do: %{pts: 0, observed_at_ms: 0, inferred: inferred, infer_us: 0, objects: []}

  @doc """
  One frame of the shape `decode_au/4` hands over: a 2x2 content rectangle
  from a 4x4 source, in a 4x4 model rect — small enough to eyeball, padded
  enough that the letterbox keys mean something.
  """
  def decoded_frame(overrides \\ []) do
    Map.merge(
      %{
        payload: :binary.copy(<<0, 0, 0>>, 4),
        width: 2,
        height: 2,
        orig_width: 4,
        orig_height: 4,
        pts: 0,
        observed_at_ms: 0,
        scale_x: 0.5,
        scale_y: 0.5,
        pad_w: 2,
        pad_h: 2,
        motion: nil
      },
      Map.new(overrides)
    )
  end

  @doc """
  One decoded frame through `Cairn.Native.Host.push_frame/5`, spelled the way
  `Cairn.Pipeline.InferSink` spells it — for tests that only care that a push
  happened, not what it carried.
  """
  def host_push(host, camera_id, pts \\ 0) do
    frame = decoded_frame(pts: pts)

    meta =
      Map.take(frame, [:width, :height, :orig_width, :orig_height, :pts, :observed_at_ms, :motion])

    Cairn.Native.Host.push_frame(host, camera_id, frame.payload, meta, {1, 90_000})
  end

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
