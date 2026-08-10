defmodule Cairn.Pipeline.InferenceTest do
  # One global control map drives the stubs, and the host is named.
  use ExUnit.Case, async: false

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  alias Cairn.CanaryStub
  alias Cairn.Config.Camera
  alias Cairn.Native.Host
  alias Cairn.NativeStub
  alias Cairn.Pipeline.{Decoder, DetectSink, Inference, Picker}
  alias Cairn.Pipeline.Inference.Detections
  alias Membrane.Buffer
  alias Membrane.Testing

  @moduletag :capture_log

  @control NativeStub.control()
  @keyframe <<0, 0, 1, 0x67, 0x42, 0xC0, 0x1F, 0, 0, 1, 0x68, 0xCE, 0x3C, 0, 0, 1, 0x65, 0x88>>
  # AUD then a non-IDR slice.
  @interframe <<0, 0, 1, 0x09, 0x30, 0, 0, 1, 0x41, 0x9A, 0x02>>
  @gop 15
  # What `Cairn.Pipeline.Decoder` declares for the stub's decoded frames.
  @format %Membrane.RawVideo{
    width: 2,
    height: 2,
    framerate: nil,
    pixel_format: :RGB,
    aligned: true
  }
  @policy %{
    pre: 5,
    post: 10,
    max: 300,
    track: %{"person" => %{min_score: 0.4}},
    record: %{"person" => %{min_score: 0.6}}
  }

  setup do
    :persistent_term.put(@control, %{test: self()})
    on_exit(fn -> :persistent_term.erase(@control) end)

    camera_id = "infer_#{System.unique_integer([:positive])}"

    %{
      camera_id: camera_id,
      camera: %Camera{id: camera_id, rtsp_url: "rtsp://h/1"},
      epoch: Cairn.ULID.generate()
    }
  end

  defp control(attrs) do
    :persistent_term.put(@control, Map.merge(:persistent_term.get(@control, %{}), attrs))
  end

  defp start_host(opts \\ []) do
    name = :"infer_host_#{System.unique_integer([:positive])}"

    defaults = [
      name: name,
      native_module: NativeStub,
      ort_module: Cairn.CairnOrtStub,
      canary_module: CanaryStub,
      config: %{model: "m.onnx", backend: "ort"}
    ]

    start_supervised!({Host, Keyword.merge(defaults, opts)}, id: name)
    name
  end

  defp element(ctx, opts \\ []) do
    options =
      struct(
        Inference,
        Keyword.merge(
          [
            session: {Host, ctx.host},
            stream_id: ctx.camera_id,
            stream_params: %{stream_epoch: ctx.epoch},
            reopen_cooldown_ms: 0
          ],
          opts
        )
      )

    {[], state} = Inference.handle_init(%{}, options)
    state
  end

  defp playing(state) do
    {actions, state} = Inference.handle_playing(%{}, state)
    # the decoder's stream format always precedes its first buffer
    {[], state} = Inference.handle_stream_format(:input, @format, %{}, state)
    {actions, state}
  end

  # One of `Cairn.Pipeline.Decoder`'s buffers, as the stub decoder mints them.
  defp frame_buffer(pts) do
    frame = NativeStub.decoded_frame(pts: pts)

    %Buffer{
      payload: frame.payload,
      pts: pts,
      metadata:
        Map.take(frame, [
          :orig_width,
          :orig_height,
          :scale_x,
          :scale_y,
          :pad_w,
          :pad_h,
          :observed_at_ms,
          :motion
        ])
    }
  end

  defp feed(state, pts \\ 1) do
    Inference.handle_buffer(:input, frame_buffer(pts), %{}, state)
  end

  describe "the stream's session" do
    setup ctx, do: Map.put(ctx, :host, start_host())

    test "opens on the pipeline's own epoch, declares its format, demands one frame", ctx do
      {actions, state} = playing(element(ctx))

      camera_id = ctx.camera_id
      epoch = ctx.epoch
      assert_receive {:open_stream, _engine, ^camera_id, %{stream_epoch: ^epoch}}
      assert actions == [stream_format: {:output, %Detections{}}, demand: {:input, 1}]
      assert state.stream == :open
    end

    test "the scene config reaches the library", ctx do
      floors = %{"person" => 0.7}
      playing(element(ctx, stream_params: %{min_score: floors}))

      assert_receive {:open_stream, _engine, _camera_id, %{min_score: ^floors}}
    end
  end

  describe "one frame" do
    setup ctx, do: Map.put(ctx, :host, start_host())

    test "becomes one Detections buffer carrying the library's observations", ctx do
      {_actions, state} = playing(element(ctx))
      {actions, state} = feed(state, 42)

      assert [buffer: {:output, out}, demand: {:input, 1}] = actions
      assert out.payload == <<>>
      assert out.pts == 42
      assert [%{inferred: true, objects: []}] = out.metadata.observations
      assert state.pushed == 1
    end

    test "is pushed with the decoder's metadata and a membrane-time base", ctx do
      control(%{
        push_frame: fn _stream, payload, meta, time_base ->
          send(self(), {:pushed, payload, meta, time_base})
          {:ok, {[], []}}
        end
      })

      {_actions, state} = playing(element(ctx))
      {_actions, _state} = feed(state, 42)

      assert_received {:pushed, payload, meta, {1, 1_000_000_000}}
      assert payload == NativeStub.decoded_frame().payload

      # the payload's geometry from the stream format, the source's from the
      # buffer, the frame's own timestamp from `buffer.pts`
      assert meta == %{
               width: 2,
               height: 2,
               orig_width: 4,
               orig_height: 4,
               pts: 42,
               observed_at_ms: 0,
               motion: nil
             }
    end
  end

  describe "errors" do
    setup ctx, do: Map.put(ctx, :host, start_host())

    test "an engine-fatal one stops the element instead of calling again", ctx do
      control(%{push_frame: fn _s, _p, _m, _tb -> {:error, {:model_load, "no such graph"}} end})

      {_actions, state} = playing(element(ctx))
      {actions, state} = feed(state)

      # No action at all, deliberately: parking is the whole effect, and the
      # parent has nothing it could do with a notification.
      assert actions == []
      assert state.engine == :dead

      # nothing is demanded any more, so no further frame can reach the dead engine
      {actions, _state} = feed(state)
      assert actions == []
    end

    test "a stream-fatal one reopens rather than giving up", ctx do
      control(%{push_frame: fn _s, _p, _m, _tb -> {:error, {:panicked, "stage panicked"}} end})

      {_actions, state} = playing(element(ctx))
      assert_receive {:open_stream, _engine, _camera_id, _params}

      {actions, state} = feed(state)
      assert actions == [demand: {:input, 1}]
      assert state.stream == :closed

      control(%{push_frame: nil})
      {_actions, state} = feed(state)

      assert state.stream == :open
      assert_receive {:open_stream, _engine, _camera_id, _params}
    end

    test "a per-frame one is counted and the element keeps running", ctx do
      control(%{push_frame: fn _s, _p, _m, _tb -> {:error, {:infer, "one bad pass"}} end})

      {_actions, state} = playing(element(ctx))
      {actions, state} = feed(state)

      assert actions == [demand: {:input, 1}]
      assert state.stream == :open
      assert state.errors == 1
    end

    test "a refused open costs the frame, not the session — and the drop is counted", ctx do
      host = start_host(config: nil)
      {actions, state} = playing(element(%{ctx | host: host}))

      assert actions == [stream_format: {:output, %Detections{}}, demand: {:input, 1}]
      assert state.stream == :closed

      {actions, state} = feed(state)
      assert actions == [demand: {:input, 1}]
      assert state.stream == :closed
      assert state.dropped == 1
    end

    test "a buffer without the decoder's metadata is dropped and counted, not crashed on", ctx do
      {_actions, state} = playing(element(ctx))

      buffer = %Buffer{payload: <<0, 0, 0>>, pts: 1, metadata: %{}}
      {actions, state} = Inference.handle_buffer(:input, buffer, %{}, state)

      assert actions == [demand: {:input, 1}]
      assert state.dropped == 1
    end

    test "a buffer that precedes its stream format is dropped and counted, not crashed on", ctx do
      {actions, state} = Inference.handle_playing(%{}, element(ctx))
      assert [stream_format: _, demand: _] = actions
      assert state.stream == :open

      {actions, state} = Inference.handle_buffer(:input, frame_buffer(1), %{}, state)
      assert actions == [demand: {:input, 1}]
      assert state.dropped == 1
    end
  end

  describe "the branch under load" do
    # The REAL detect branch, all four elements, over the stubbed NIFs.
    # 30 fps: the fastest the gate can be told to run, so the pacing tests
    # collect enough samples to measure inside a second.
    setup ctx do
      Map.put(
        ctx,
        :host,
        start_host(config: %{model: "m.onnx", backend: "ort", sample_fps: 30})
      )
    end

    defp branch(ctx, count, interval_ms) do
      branch_over(
        ctx,
        for(pts <- 1..count, do: %Buffer{payload: @keyframe, pts: pts}),
        interval_ms
      )
    end

    defp branch_over(ctx, buffers, interval_ms) do
      Testing.Pipeline.start_link_supervised!(
        spec: [
          child(:source, %Cairn.PushSource{buffers: buffers, interval_ms: interval_ms})
          |> child(:picker, Picker)
          |> via_in(:input, target_queue_size: 1, min_demand_factor: 0.5)
          |> child(:decoder, %Decoder{camera_id: ctx.camera_id, host: ctx.host})
          |> via_in(:input, target_queue_size: 1, min_demand_factor: 0.5)
          |> child(:infer, %Inference{
            session: {Host, ctx.host},
            stream_id: ctx.camera_id,
            stream_params: %{stream_epoch: ctx.epoch}
          })
          |> child(:detect, %DetectSink{
            camera: ctx.camera,
            policy: @policy,
            epoch: ctx.epoch,
            tracker: self()
          })
        ]
      )
    end

    test "decode runs at the source's rate; the model at the gate's; the tracker hears it all",
         ctx do
      test = self()

      control(%{
        decode_au: fn _d, _au, pts, sample ->
          send(test, {:decoded, System.monotonic_time(:millisecond)})
          {:ok, {true, if(sample, do: NativeStub.decoded_frame(pts: pts), else: nil)}}
        end,
        push_frame: fn _stream, _payload, _meta, _tb ->
          send(test, {:pushed, System.monotonic_time(:millisecond)})
          {:ok, {[NativeStub.frame()], []}}
        end
      })

      # A ~1 ms source over a GOP-shaped stream: every access unit must reach
      # the decoder (a gate anywhere upstream of it could only admit
      # keyframe-headed AUs and shows up as a fifteenth of the decodes), while
      # the model is offered `sample_fps`, not the source's rate.
      buffers =
        for pts <- 1..2_000 do
          %Buffer{payload: if(rem(pts, @gop) == 1, do: @keyframe, else: @interframe), pts: pts}
        end

      pipeline = branch_over(ctx, buffers, 1)
      Process.sleep(1_200)
      Testing.Pipeline.terminate(pipeline)

      decodes = flush({:decoded, nil})
      pushes = flush({:pushed, nil})

      assert length(decodes) >= 200,
             "only #{length(decodes)} access units reached the decoder in 1.2 s"

      assert length(decodes) > 2 * div(length(decodes), @gop) + 30,
             "the decode rate collapsed toward the keyframe rate"

      decode_gaps = gaps(decodes)

      assert Enum.min(decode_gaps) < 10,
             "decode is being paced (min gap #{Enum.min(decode_gaps)} ms): the gate belongs " <>
               "after the decoder, not before it"

      # ~36 model offers in 1.2 s at 30 fps; deliberately loose bounds — a
      # starved CI scheduler stretches the run but can neither multiply
      # offers past the gate's arithmetic nor pace them closer than the
      # interval. The lower bound only rules out a gate stuck closed.
      assert length(pushes) in 5..55,
             "#{length(pushes)} model offers in 1.2 s against a 30 fps gate"

      assert Enum.min(gaps(pushes)) >= 20,
             "two model offers landed #{Enum.min(gaps(pushes))} ms apart: the gate is not pacing"

      # …and every pass's observations crossed the Detections seam into the
      # dispatch cast — the half a `pushed` counter cannot see.
      assert detections_dispatched() >= length(pushes) - 1
    end

    defp flush({tag, _}, acc \\ []) do
      receive do
        {^tag, at} -> flush({tag, nil}, [at | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    defp gaps(instants) do
      instants
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [before, after_it] -> after_it - before end)
    end

    defp detections_dispatched(count \\ 0) do
      receive do
        {:"$gen_cast", {:detections, _camera, _policy, _observation}} ->
          detections_dispatched(count + 1)
      after
        0 -> count
      end
    end

    test "exactly one call is in flight", ctx do
      test = self()

      control(%{
        push_frame: fn _stream, _payload, meta, _tb ->
          send(test, {:started, meta.pts, self()})
          receive do: (:release -> :ok)
          {:ok, {[], []}}
        end
      })

      # a paced source, so there is still media to pick up after the release
      pipeline = branch(ctx, 200, 10)

      assert_receive {:started, _pts, element}, 5_000
      refute_receive {:started, _pts, _element}, 300

      send(element, :release)
      assert_receive {:started, _pts, ^element}, 5_000
      refute_receive {:started, _pts, _element}, 300

      # let the branch run free, so the pipeline can be shut down politely
      control(%{push_frame: nil})
      send(element, :release)
      Testing.Pipeline.terminate(pipeline)
    end

    test "a slow push bounds the rate, and the surplus is replaced rather than held", ctx do
      test = self()

      control(%{
        push_frame: fn _stream, _payload, meta, _tb ->
          send(test, {:pushed, meta.pts})
          Process.sleep(50)
          {:ok, {[], []}}
        end
      })

      pipeline = branch(ctx, 2_000, 1)
      Process.sleep(500)

      Testing.Pipeline.notify_child(pipeline, :decoder, :stats)
      assert_pipeline_notified(pipeline, :decoder, {:stats, decoder}, 5_000)
      Testing.Pipeline.notify_child(pipeline, :infer, :stats)
      assert_pipeline_notified(pipeline, :infer, {:stats, infer}, 5_000)

      # 50 ms a call against a 33 ms sample interval: frames sampled while the
      # element was busy were replaced in the decoder's slot — newest wins —
      # and none of them queued anywhere.
      assert infer.pushed < 15
      assert decoder.replaced >= 1
      assert decoder.emitted <= infer.pushed + 1
      # every sample is accounted for: emitted, replaced, or (at most one)
      # still in the slot
      assert decoder.sampled >= decoder.emitted + decoder.replaced
      assert decoder.sampled <= decoder.emitted + decoder.replaced + 1

      Testing.Pipeline.terminate(pipeline)
    end
  end
end
