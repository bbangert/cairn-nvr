defmodule Cairn.Pipeline.InferSinkTest do
  # One global control map drives `Cairn.NativeStub`, and the host is named.
  use ExUnit.Case, async: false

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  alias Cairn.CanaryStub
  alias Cairn.Config.Camera
  alias Cairn.Native.Host
  alias Cairn.NativeStub
  alias Cairn.Observation
  alias Cairn.Pipeline.{Decoder, InferSink, Picker}
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
  # The two tiers are carried, not consulted: what the sink owes the tracker is
  # this map back, unread.
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
      policy: @policy,
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
            camera: ctx.camera,
            policy: ctx.policy,
            epoch: ctx.epoch,
            host: ctx.host,
            # the dispatch seam's injection point: this process stands in for
            # the camera's tracker and sees the casts it would have received
            tracker: self(),
            reopen_cooldown_ms: 0
          ],
          opts
        )
      )

    {[], state} = InferSink.handle_init(%{}, options)
    state
  end

  defp playing(state) do
    {actions, state} = InferSink.handle_playing(%{}, state)
    # the decoder's stream format always precedes its first buffer
    {[], state} = InferSink.handle_stream_format(:input, @format, %{}, state)
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
    InferSink.handle_buffer(:input, frame_buffer(pts), %{}, state)
  end

  describe "the stream's session" do
    setup ctx, do: Map.put(ctx, :host, start_host())

    test "opens on the pipeline's own epoch and demands one frame", ctx do
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

  describe "one frame" do
    setup ctx, do: Map.put(ctx, :host, start_host())

    test "reaches the tracker through the dispatch seam, then one more demand", ctx do
      {_actions, state} = playing(sink(ctx))
      {actions, _state} = feed(state)

      camera_id = ctx.camera_id
      epoch = ctx.epoch
      camera = ctx.camera

      # the same cast the plugin ports make, carrying the same policy —
      # `track:` and `record:` included, and neither read on the way
      assert_received {:"$gen_cast", {:detections, ^camera, @policy, observation}}
      assert %Observation{camera_id: ^camera_id, epoch: ^epoch} = observation

      # nothing goes to the parent any more: the pipeline is off the per-frame
      # path entirely
      assert actions == [demand: {:input, 1}]
    end

    test "stamps at_ms on the host's monotonic clock, like both plugin producers", ctx do
      # A wall-clock stamp keeps every intra-stream duration right and still
      # breaks the tracker: `Cairn.CameraTracker` stamps a stream cut with
      # `System.monotonic_time/1`, so a wall-clock `at_ms` lapses every
      # suspension the instant it is offered and no track can ever be adopted
      # across a reset. Nothing else in the pipeline notices.
      {_actions, state} = playing(sink(ctx))
      {_actions, _state} = feed(state)

      assert_received {:"$gen_cast", {:detections, _camera, @policy, observation}}
      assert_in_delta observation.at_ms, System.monotonic_time(:millisecond), 5_000
    end

    test "carries a refreshed policy without restarting the session", ctx do
      {_actions, state} = playing(sink(ctx))
      assert_receive {:open_stream, _engine, _camera_id, _params}

      camera = %{ctx.camera | record: %{"person" => %{min_score: 0.9}}}
      policy = Map.put(@policy, :record, %{"person" => %{min_score: 0.9}})

      {actions, state} =
        InferSink.handle_parent_notification({:policy, camera, policy}, %{}, state)

      assert actions == []

      {_actions, _state} = feed(state)
      assert_received {:"$gen_cast", {:detections, ^camera, ^policy, %Observation{}}}
      # the stream was not reopened for it
      refute_received {:open_stream, _engine, _camera_id, _params}
    end

    test "answering with several frames dispatches them in the crate's order", ctx do
      # One push, several observations — the crate's answer is a list because
      # that is the host's shape. The tracker's `at_ms` is strictly increasing
      # across them, so a reordering here would be a stream that appears to
      # run backwards.
      control(%{
        push_frame: fn _stream, _payload, _meta, _tb ->
          {:ok, {for(pts <- [90_000, 93_000, 96_000], do: %{NativeStub.frame() | pts: pts}), []}}
        end
      })

      {_actions, state} = playing(sink(ctx))
      {_actions, _state} = feed(state)

      pts_order =
        for _ <- 1..3 do
          assert_received {:"$gen_cast", {:detections, _camera, @policy, observation}}
          {observation.pts, observation.at_ms}
        end

      assert [{90_000, _}, {93_000, _}, {96_000, _}] = pts_order
      assert pts_order |> Enum.map(&elem(&1, 1)) |> then(&(&1 == Enum.sort(&1)))
      refute_received {:"$gen_cast", {:detections, _camera, _policy, _observation}}
    end

    test "is pushed with the decoder's metadata and a membrane-time base", ctx do
      control(%{
        push_frame: fn _stream, payload, meta, time_base ->
          send(self(), {:pushed, payload, meta, time_base})
          {:ok, {[], []}}
        end
      })

      {_actions, state} = playing(sink(ctx))
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

    test "an engine-fatal one stops the branch instead of calling again", ctx do
      control(%{push_frame: fn _s, _p, _m, _tb -> {:error, {:model_load, "no such graph"}} end})

      {_actions, state} = playing(sink(ctx))
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

      {_actions, state} = playing(sink(ctx))
      assert_receive {:open_stream, _engine, _camera_id, _params}

      {actions, state} = feed(state)
      assert actions == [demand: {:input, 1}]
      assert state.stream == :closed

      control(%{push_frame: nil})
      {_actions, state} = feed(state)

      assert state.stream == :open
      assert_receive {:open_stream, _engine, _camera_id, _params}
    end

    test "a per-frame one is counted and the branch keeps running", ctx do
      control(%{push_frame: fn _s, _p, _m, _tb -> {:error, {:infer, "one bad pass"}} end})

      {_actions, state} = playing(sink(ctx))
      {actions, state} = feed(state)

      assert actions == [demand: {:input, 1}]
      assert state.stream == :open
      assert state.errors == 1
    end

    test "a refused open costs the frame, not the session — and the drop is counted", ctx do
      host = start_host(config: nil)
      {actions, state} = playing(sink(%{ctx | host: host}))

      assert actions == [demand: {:input, 1}]
      assert state.stream == :closed

      {actions, state} = feed(state)
      assert actions == [demand: {:input, 1}]
      assert state.stream == :closed
      # a stuck reopen loop must not read as healthy in :stats while
      # quietly discarding frames
      assert state.dropped == 1
    end

    test "a buffer without the decoder's metadata is dropped and counted, not crashed on", ctx do
      # A producer that speaks RGB frames without the metadata contract —
      # the pad's accepted_format cannot enforce buffer metadata.
      {_actions, state} = playing(sink(ctx))

      buffer = %Buffer{payload: <<0, 0, 0>>, pts: 1, metadata: %{}}
      {actions, state} = InferSink.handle_buffer(:input, buffer, %{}, state)

      assert actions == [demand: {:input, 1}]
      assert state.dropped == 1
      refute_received {:"$gen_cast", {:detections, _camera, _policy, _observation}}
    end

    test "a buffer that precedes its stream format is dropped and counted, not crashed on", ctx do
      # `Cairn.Pipeline.Decoder` always pairs its first buffer with a
      # stream_format action, so this is unreachable from the in-tree
      # producer — but the pad contract does not enforce it, and the sink
      # must not read `content: nil` as geometry.
      {actions, state} = InferSink.handle_playing(%{}, sink(ctx))
      assert actions == [demand: {:input, 1}]
      assert state.stream == :open

      {actions, state} = InferSink.handle_buffer(:input, frame_buffer(1), %{}, state)
      assert actions == [demand: {:input, 1}]
      assert state.dropped == 1
      refute_received {:"$gen_cast", {:detections, _camera, _policy, _observation}}
    end
  end

  describe "the branch under load" do
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
          |> child(:infer, %InferSink{
            camera: ctx.camera,
            policy: ctx.policy,
            epoch: ctx.epoch,
            host: ctx.host,
            tracker: self()
          })
        ]
      )
    end

    test "decode runs at the source's rate; the model at the gate's", ctx do
      test = self()

      control(%{
        decode_au: fn _d, _au, pts, sample ->
          send(test, {:decoded, System.monotonic_time(:millisecond)})
          {:ok, {true, if(sample, do: NativeStub.decoded_frame(pts: pts), else: nil)}}
        end,
        push_frame: fn _stream, _payload, _meta, _tb ->
          send(test, {:pushed, System.monotonic_time(:millisecond)})
          {:ok, {[], []}}
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

      assert_receive {:started, _pts, sink}, 5_000
      refute_receive {:started, _pts, _sink}, 300

      send(sink, :release)
      assert_receive {:started, _pts, ^sink}, 5_000
      refute_receive {:started, _pts, _sink}, 300

      # let the branch run free, so the pipeline can be shut down politely
      control(%{push_frame: nil})
      send(sink, :release)
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
      assert_pipeline_notified(pipeline, :infer, {:stats, sink}, 5_000)

      # 50 ms a call against a 33 ms sample interval: frames sampled while the
      # sink was busy were replaced in the decoder's slot — newest wins — and
      # none of them queued anywhere.
      assert sink.pushed < 15
      assert decoder.replaced >= 1
      assert decoder.emitted <= sink.pushed + 1
      # every sample is accounted for: emitted, replaced, or (at most one)
      # still in the slot
      assert decoder.sampled >= decoder.emitted + decoder.replaced
      assert decoder.sampled <= decoder.emitted + decoder.replaced + 1

      Testing.Pipeline.terminate(pipeline)
    end
  end
end
