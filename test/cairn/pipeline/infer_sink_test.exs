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
  alias Cairn.Pipeline.{InferSink, Picker}
  alias Membrane.Buffer
  alias Membrane.Testing

  @moduletag :capture_log

  @control NativeStub.control()
  @keyframe <<0, 0, 1, 0x67, 0x42, 0xC0, 0x1F, 0, 0, 1, 0x68, 0xCE, 0x3C, 0, 0, 1, 0x65, 0x88>>
  # AUD then a non-IDR slice.
  @interframe <<0, 0, 1, 0x09, 0x30, 0, 0, 1, 0x41, 0x9A, 0x02>>
  @gop 15
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
      # One push, several decoded frames — the crate's normal answer when a
      # single AU carries more than one picture. The tracker's `at_ms` is
      # strictly increasing across them, so a reordering here would be a stream
      # that appears to run backwards.
      control(%{
        push_au: fn _stream, _au, _pts, _tb ->
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

      # No action at all, deliberately: parking is the whole effect, and the
      # parent has nothing it could do with a notification.
      assert actions == []
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

    test "the branch paces nothing: the model is offered every AU the source sends", ctx do
      test = self()

      control(%{
        push_au: fn _stream, _au, _pts, _tb ->
          send(test, {:pushed, System.monotonic_time(:millisecond)})
          {:ok, {[], []}}
        end
      })

      # A ~1 ms source and a push that costs nothing, so nothing here has a
      # reason to drop and the rate is the source's own.
      pipeline = branch(ctx, 2_000, 1)
      Process.sleep(1_200)
      Testing.Pipeline.terminate(pipeline)

      gaps =
        flush_pushes()
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [before, after_it] -> after_it - before end)

      assert length(gaps) >= 200, "too few pushes in 1.2 s to measure a rate: #{length(gaps)}"

      # A gate in this branch at any plausible `sample_fps` would put a floor of
      # tens of milliseconds under every gap. The rate belongs to the crate's
      # `Stream::push_au`, which this stub replaces.
      assert Enum.min(gaps) < 10,
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

    test "a detection per access unit, and not one per keyframe", ctx do
      # The rate belongs to the crate, which CI has no library for, so the branch
      # itself must impose no floor of its own. A gate reintroduced anywhere
      # between the tee and the model can only admit keyframe-headed AUs — a
      # stateful decoder needs its references — and shows up here as a fifteenth
      # of the detections.
      buffers =
        for pts <- 1..900 do
          %Buffer{payload: if(rem(pts, @gop) == 1, do: @keyframe, else: @interframe), pts: pts}
        end

      pipeline = branch_over(ctx, buffers, 1)
      Process.sleep(1_000)

      Testing.Pipeline.notify_child(pipeline, :picker, :stats)
      assert_pipeline_notified(pipeline, :picker, {:stats, picker}, 5_000)
      Testing.Pipeline.notify_child(pipeline, :infer, :stats)
      assert_pipeline_notified(pipeline, :infer, {:stats, sink}, 5_000)
      Testing.Pipeline.terminate(pipeline)

      aus = picker.dropped + picker.emitted
      keyframes = ceil(aus / @gop)
      assert aus >= 200, "only #{aus} access units reached the picker: nothing is measured"

      # Nothing here is slow, so nothing here has a reason to shed.
      assert sink.pushed >= div(aus * 9, 10),
             "#{sink.pushed} model offers from #{aus} access units " <>
               "(#{keyframes} of them keyframes): something is thinning the branch"

      # …and every one of them reached the tracker through the dispatch seam,
      # which is the half a `pushed` counter cannot see.
      assert detections_dispatched() >= sink.pushed - 1
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
