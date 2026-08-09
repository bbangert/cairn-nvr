defmodule Cairn.Pipeline.InferSinkTest do
  # One global control map drives `Cairn.NativeStub`, and the host is named.
  use ExUnit.Case, async: false

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  alias Cairn.CanaryStub
  alias Cairn.Native.Host
  alias Cairn.NativeStub
  alias Cairn.Observation
  alias Cairn.Pipeline.{InferSink, Picker}
  alias Membrane.Buffer
  alias Membrane.Testing

  @moduletag :capture_log

  @control NativeStub.control()
  @keyframe <<0, 0, 1, 0x67, 0x42, 0xC0, 0x1F, 0, 0, 1, 0x68, 0xCE, 0x3C, 0, 0, 1, 0x65, 0x88>>

  setup do
    :persistent_term.put(@control, %{test: self()})
    on_exit(fn -> :persistent_term.erase(@control) end)

    %{camera_id: "infer_#{System.unique_integer([:positive])}", epoch: Cairn.ULID.generate()}
  end

  defp control(attrs) do
    :persistent_term.put(@control, Map.merge(:persistent_term.get(@control, %{}), attrs))
  end

  defp start_host(opts \\ []) do
    name = :"infer_host_#{System.unique_integer([:positive])}"

    defaults = [
      name: name,
      native_module: NativeStub,
      canary_module: CanaryStub,
      config: %{model: "m.onnx", backend: "ort"}
    ]

    start_supervised!({Host, Keyword.merge(defaults, opts)}, id: name)
    name
  end

  defp sink(ctx, opts \\ []) do
    options =
      struct(
        InferSink,
        Keyword.merge(
          [
            camera_id: ctx.camera_id,
            epoch: ctx.epoch,
            host: ctx.host,
            reopen_cooldown_ms: 0
          ],
          opts
        )
      )

    {[], state} = InferSink.handle_init(%{}, options)
    state
  end

  defp playing(state), do: InferSink.handle_playing(%{}, state)

  defp feed(state, pts \\ 1) do
    InferSink.handle_buffer(:input, %Buffer{payload: @keyframe, pts: pts}, %{}, state)
  end

  describe "the stream's session" do
    setup ctx, do: Map.put(ctx, :host, start_host())

    test "opens on the pipeline's own epoch and demands one AU", ctx do
      {actions, state} = playing(sink(ctx))

      camera_id = ctx.camera_id
      epoch = ctx.epoch
      assert_receive {:open_stream, _engine, ^camera_id, %{stream_epoch: ^epoch}}
      assert actions == [demand: {:input, 1}]
      assert state.stream == :open
    end

    test "the scene config reaches the crate", ctx do
      floors = %{"person" => 0.7}
      playing(sink(ctx, stream_params: %{min_score: floors}))

      assert_receive {:open_stream, _engine, _camera_id, %{min_score: ^floors}}
    end
  end

  describe "one AU" do
    setup ctx, do: Map.put(ctx, :host, start_host())

    test "becomes observations for the tracker seam, then one more demand", ctx do
      {_actions, state} = playing(sink(ctx))
      {actions, _state} = feed(state)

      camera_id = ctx.camera_id
      epoch = ctx.epoch

      assert [notify_parent: {:observations, ^camera_id, [observation]}, demand: {:input, 1}] =
               actions

      assert %Observation{camera_id: ^camera_id, epoch: ^epoch} = observation
    end

    test "is pushed with a membrane-time base the crate can rescale", ctx do
      control(%{
        push_au: fn _stream, au, pts, time_base ->
          send(self(), {:pushed, au, pts, time_base})
          {:ok, {[], []}}
        end
      })

      {_actions, state} = playing(sink(ctx))
      {_actions, _state} = feed(state, 42)

      assert_received {:pushed, @keyframe, 42, {1, 1_000_000_000}}
    end
  end

  describe "errors" do
    setup ctx, do: Map.put(ctx, :host, start_host())

    test "an engine-fatal one stops the branch instead of calling again", ctx do
      control(%{push_au: fn _s, _au, _pts, _tb -> {:error, {:model_load, "no such graph"}} end})

      {_actions, state} = playing(sink(ctx))
      {actions, state} = feed(state)

      assert actions == [notify_parent: {:engine_fatal, :model_load}]
      assert state.engine == :dead

      # nothing is demanded any more, so no further AU can reach the dead engine
      {actions, _state} = feed(state)
      assert actions == []
    end

    test "a stream-fatal one reopens rather than giving up", ctx do
      control(%{push_au: fn _s, _au, _pts, _tb -> {:error, {:panicked, "stage panicked"}} end})

      {_actions, state} = playing(sink(ctx))
      assert_receive {:open_stream, _engine, _camera_id, _params}

      {actions, state} = feed(state)
      assert actions == [demand: {:input, 1}]
      assert state.stream == :closed

      control(%{push_au: nil})
      {_actions, state} = feed(state)

      assert state.stream == :open
      assert_receive {:open_stream, _engine, _camera_id, _params}
    end

    test "a per-frame one is counted and the branch keeps running", ctx do
      control(%{push_au: fn _s, _au, _pts, _tb -> {:error, {:infer, "one bad pass"}} end})

      {_actions, state} = playing(sink(ctx))
      {actions, state} = feed(state)

      assert actions == [demand: {:input, 1}]
      assert state.stream == :open
      assert state.errors == 1
    end

    test "a refused open costs the AU, not the session", ctx do
      host = start_host(config: nil)
      {actions, state} = playing(sink(%{ctx | host: host}))

      assert actions == [demand: {:input, 1}]
      assert state.stream == :closed

      {actions, state} = feed(state)
      assert actions == [demand: {:input, 1}]
      assert state.stream == :closed
    end
  end

  describe "the branch under load" do
    setup ctx, do: Map.put(ctx, :host, start_host())

    defp branch(ctx, count, interval_ms \\ 0) do
      buffers = for pts <- 1..count, do: %Buffer{payload: @keyframe, pts: pts}

      Testing.Pipeline.start_link_supervised!(
        spec: [
          child(:source, %Cairn.PushSource{buffers: buffers, interval_ms: interval_ms})
          # 30 fps, the picker's fastest setting: 34 ms between AUs
          |> child(:picker, %Picker{sample_fps: 30})
          |> via_in(:input, target_queue_size: 1, min_demand_factor: 0.5)
          |> child(:infer, %InferSink{
            camera_id: ctx.camera_id,
            epoch: ctx.epoch,
            host: ctx.host
          })
        ]
      )
    end

    test "the branch reaches the model at the rate that was asked for", ctx do
      test = self()

      control(%{
        push_au: fn _stream, _au, _pts, _tb ->
          send(test, {:pushed, System.monotonic_time(:millisecond)})
          {:ok, {[], []}}
        end
      })

      # A source an order of magnitude faster than the gate and a push that costs
      # nothing, so the picker is the only thing pacing this.
      pipeline = branch(ctx, 2_000, 1)
      Process.sleep(1_200)
      Testing.Pipeline.terminate(pipeline)

      gaps =
        flush_pushes()
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [before, after_it] -> after_it - before end)

      assert length(gaps) >= 20, "too few pushes in 1.2 s to measure a rate: #{inspect(gaps)}"

      # The smallest gap is the interval itself: `due?` never fires early, so
      # jitter only ever lengthens one. Anything added to `interval_ms`, or a
      # second gate at the same nominal rate downstream, shows up here.
      assert Enum.min(gaps) in 34..37,
             "gaps over #{length(gaps)} pushes: min #{Enum.min(gaps)} ms, " <>
               "max #{Enum.max(gaps)} ms"
    end

    defp flush_pushes(acc \\ []) do
      receive do
        {:pushed, at} -> flush_pushes([at | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    test "exactly one call is in flight", ctx do
      test = self()

      control(%{
        push_au: fn _stream, _au, pts, _tb ->
          send(test, {:started, pts, self()})
          receive do: (:release -> :ok)
          {:ok, {[], []}}
        end
      })

      # a paced source, so there is still media to pick up after the release
      pipeline = branch(ctx, 50, 10)

      assert_receive {:started, _pts, sink}, 5_000
      refute_receive {:started, _pts, _sink}, 300

      send(sink, :release)
      assert_receive {:started, _pts, ^sink}, 5_000
      refute_receive {:started, _pts, _sink}, 300

      # let the branch run free, so the pipeline can be shut down politely
      control(%{push_au: nil})
      send(sink, :release)
      Testing.Pipeline.terminate(pipeline)
    end

    test "a slow push bounds the rate, and the surplus is dropped rather than held", ctx do
      test = self()

      control(%{
        push_au: fn _stream, _au, pts, _tb ->
          send(test, {:pushed, pts})
          Process.sleep(20)
          {:ok, {[], []}}
        end
      })

      pipeline = branch(ctx, 400)
      Process.sleep(300)

      Testing.Pipeline.notify_child(pipeline, :picker, :stats)
      assert_pipeline_notified(pipeline, :picker, {:stats, picker}, 5_000)
      Testing.Pipeline.notify_child(pipeline, :infer, :stats)
      assert_pipeline_notified(pipeline, :infer, {:stats, sink}, 5_000)

      # 20 ms a call over ~300 ms: an order of magnitude under the 400 offered,
      # and every one not taken was destroyed at depth 1 rather than queued.
      assert sink.pushed < 50
      assert picker.emitted <= sink.pushed + 1
      # 400 minus whichever AU is sitting in the slot when the stats are read
      assert (picker.dropped + picker.emitted) in 399..400

      Testing.Pipeline.terminate(pipeline)
    end
  end
end
