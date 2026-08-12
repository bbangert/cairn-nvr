defmodule Cairn.Pipeline.CameraTest do
  # The PipelineOwner case starts a real (stubbed) pipeline.
  use ExUnit.Case, async: false

  alias Cairn.Config
  alias Cairn.Config.{Camera, PluginGroup, Profile}
  alias Cairn.Pipeline.Camera, as: Pipeline

  defmodule RecordingPipeline do
    @moduledoc false
    use Membrane.Pipeline

    # `owner:` is the pipeline owner, not the test, so the probe is registered
    # by name.
    @impl true
    def handle_init(_ctx, opts) do
      send(Process.whereis(:camera_test_probe), {:pipeline_opts, opts})
      {[], %{}}
    end

    # The owner flushes before it terminates; without this the stub logs an
    # unhandled-message warning per test.
    @impl true
    def handle_info(:flush, _ctx, state), do: {[], state}
  end

  @policy %{pre: 5, post: 10, max: 300, track: nil, record: nil}

  defp init(opts) do
    Pipeline.handle_init(
      %{},
      Keyword.merge([camera: %Camera{id: "cam"}, owner: self()], opts)
    )
  end

  defp spec(opts) do
    {[spec: spec], _state} = init(opts)
    spec
  end

  # The detect branch needs a policy; every test that wants one wants the same
  # one.
  defp detect(opts \\ []), do: Keyword.put_new(opts, :policy, @policy)

  defp children(spec) do
    for builder <- spec, {name, definition, _opts} <- builder.children, into: %{} do
      {name, module(definition)}
    end
  end

  defp module(%module{}), do: module
  defp module(module) when is_atom(module), do: module

  defp links(spec), do: Enum.flat_map(spec, & &1.links)

  defp child(spec, name) do
    Enum.find_value(spec, fn builder ->
      Enum.find_value(builder.children, fn
        {^name, definition, _opts} -> definition
        _other -> nil
      end)
    end)
  end

  defp flow_control(module, pad) do
    # A bin's pads carry no flow control at all, which is itself the answer:
    # `:manual` is not expressible there.
    Map.get(module.membrane_pads()[pad], :flow_control, :bin)
  end

  describe "the long-lived half" do
    test "the tagger sits between ingest and tee, carrying the owner's reason" do
      spec = spec(initial_reason: :stall_bounce)

      assert %Cairn.Pipeline.EpochTagger{camera_id: "cam", initial_reason: :stall_bounce} =
               child(spec, :tagger)

      assert Enum.any?(links(spec), &match?(%{from: :demuxer, to: :tagger}, &1))
      assert Enum.any?(links(spec), &match?(%{from: :tagger, to: :tee}, &1))
    end

    test "the first mint is :started unless the owner says otherwise" do
      assert %Cairn.Pipeline.EpochTagger{initial_reason: :started} = child(spec([]), :tagger)
    end

    test "both cuts hang off the tee, each with its session-0 branch linked" do
      spec = spec([])
      children = children(spec)

      assert children[:record_cut] == Cairn.Pipeline.SessionCut
      assert children[:rtp_cut] == Cairn.Pipeline.SessionCut
      assert children[{:cmaf_parser, 0}] == Membrane.H264.Parser
      assert children[{:cmaf, 0}] == Membrane.MP4.Muxer.CMAF
      assert children[{:ring_sink, 0}] == Cairn.Pipeline.RingBufferSink
      assert children[{:rtp_out, 0}] == Cairn.Pipeline.RTPOut

      # …and nothing in either branch carries an epoch: it arrives in band.
      assert %Cairn.Pipeline.RingBufferSink{camera_id: "cam"} = child(spec, {:ring_sink, 0})
    end
  end

  describe "a session boundary" do
    test "links the next branch at once and drops the drained one after the grace" do
      {_actions, state} = init(flush_grace_ms: 5)

      assert {[spec: spec], state} =
               Pipeline.handle_child_notification({:session_ended, 0}, :record_cut, %{}, state)

      # The gate is queueing for this pad already; waiting would be recording
      # thrown away.
      assert Map.keys(children(spec)) |> Enum.sort() ==
               Enum.sort([{:cmaf_parser, 1}, {:cmaf, 1}, {:ring_sink, 1}])

      assert state.sessions.record_cut == 1
      # the other cut is untouched: each gate counts its own sessions
      assert state.sessions.rtp_cut == 0
      # scheduled for drop but not yet dropped
      assert state.pending_drops == 1

      # EOS is still walking parser -> muxer -> ring sink when the gate speaks,
      # so removal waits out the flush grace.
      assert_receive {:drop_branch, :record_cut, 0}, 500

      ctx = %{children: %{{:cmaf_parser, 0} => :_, {:cmaf, 0} => :_, {:ring_sink, 0} => :_}}

      assert {[remove_children: removed], new_state} =
               Pipeline.handle_info({:drop_branch, :record_cut, 0}, ctx, state)

      assert Enum.sort(removed) == Enum.sort([{:cmaf_parser, 0}, {:cmaf, 0}, {:ring_sink, 0}])
      assert new_state == %{state | pending_drops: 0}
    end

    test "the rtp cut rebuilds only its own child" do
      {_actions, state} = init([])

      assert {[spec: spec], state} =
               Pipeline.handle_child_notification({:session_ended, 3}, :rtp_cut, %{}, state)

      assert Map.keys(children(spec)) == [{:rtp_out, 4}]
      assert state.sessions.rtp_cut == 4
    end

    test "a branch already gone is not removed twice" do
      {_actions, state} = init([])
      # mirrors the pairing every real {:drop_branch, ...} has: one prior
      # {:session_ended, ...} incremented this
      state = %{state | pending_drops: 1}

      assert {[remove_children: []], new_state} =
               Pipeline.handle_info({:drop_branch, :rtp_cut, 0}, %{children: %{}}, state)

      assert new_state == %{state | pending_drops: 0}
    end
  end

  describe "the source's notifications" do
    test "reach the owner verbatim — the escalation is the owner's to decide" do
      {_actions, state} = init([])
      tracks = [%{type: :video, fmtp: nil, rtpmap: %{encoding: "H264", clock_rate: 90_000}}]

      assert {[], state} =
               Pipeline.handle_child_notification(
                 {:stream_connected, :main, tracks},
                 :source,
                 %{},
                 state
               )

      assert_receive {:stream_connected, :main, ^tracks}

      assert {[], _state} =
               Pipeline.handle_child_notification({:stream_lost, :main}, :source, %{}, state)

      assert_receive {:stream_lost, :main}

      assert {[], _state} =
               Pipeline.handle_child_notification(
                 {:stream_backoff, :main, :refused},
                 :source,
                 %{},
                 state
               )

      assert_receive {:stream_backoff, :main, :refused}
    end

    @tag :capture_log
    test "a reconnect on a different codec is logged; a respelt one is not" do
      {_actions, state} = init([])

      connect = fn state, encoding ->
        tracks = [%{type: :video, fmtp: nil, rtpmap: %{encoding: encoding, clock_rate: 90_000}}]

        {[], state} =
          Pipeline.handle_child_notification(
            {:stream_connected, :main, tracks},
            :source,
            %{},
            state
          )

        state
      end

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          state |> connect.("H264") |> connect.("h264")
        end)

      refute log =~ "track identity"

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          state |> connect.("H264") |> connect.("H265")
        end)

      assert log =~ "track identity"
    end

    test "the detect sink's stats reach the owner, which is what the watchdog reads" do
      {_actions, state} = init(detect: detect())
      stats = %{dispatched: 1, dropped: 0, last_buffer_at_ms: -12_345}

      assert {[], _state} =
               Pipeline.handle_child_notification({:stats, stats}, :detect, %{}, state)

      assert_receive {:stats, ^stats}
    end
  end

  describe "the detect branch" do
    test "is not built for a camera with no plugin configured" do
      children = children(spec([]))

      refute Map.has_key?(children, :picker)
      refute Map.has_key?(children, :infer)
      assert Map.has_key?(children, {:ring_sink, 0})
    end

    test "hangs off the tee: picker, decoder, inference, then the sink" do
      spec = spec(detect: detect())
      links = links(spec)

      assert Enum.any?(links, &match?(%{from: :tee, to: :picker}, &1))
      assert Enum.any?(links, &match?(%{from: :infer, to: :detect}, &1))

      # One AU in flight into the decoder, one sampled frame into inference.
      for {from, to} <- [{:picker, :decoder}, {:decoder, :infer}] do
        assert %{to_pad_props: props} =
                 Enum.find(links, &match?(%{from: ^from, to: ^to}, &1)),
               "no #{from} -> #{to} link"

        assert props.target_queue_size == 1
        assert props.min_demand_factor == 0.5
      end
    end

    test "the picker takes no options — the decoder's gate owns the rate" do
      assert child(spec(detect: detect()), :picker) == Cairn.Pipeline.Picker
    end

    test "the decoder and inference share one stream_params, epoch-free" do
      params = %{min_score: %{"person" => 0.6}}
      spec = spec(detect: detect(stream_params: params))

      assert %Cairn.Pipeline.Decoder{camera_id: "cam", stream_params: ^params} =
               child(spec, :decoder)

      # The epoch is no longer an option on either: inference reads it off the
      # frames and reopens its stream when it changes.
      assert %Cairn.Pipeline.Inference{
               session: {Cairn.Native.Host, Cairn.Native.Host},
               stream_id: "cam",
               stream_params: ^params
             } = child(spec, :infer)
    end

    test "default ingest is the ffmpeg bridge: BridgeSource into the TS demuxer" do
      spec = spec(detect: detect())
      children = children(spec)

      assert children[:demuxer] == Membrane.MPEG.TS.Demuxer
      assert %Cairn.Pipeline.BridgeSource{camera_id: "cam"} = child(spec, :source)
    end

    test "rtsp ingest is the source element alone — it declares its own format" do
      camera = %Camera{id: "cam", rtsp_url: "rtsp://cam/main"}
      spec = spec(camera: camera, detect: detect(), ingest: :rtsp)
      children = children(spec)

      assert %Membrane.RTSPDualStream.Source{stream_uri: "rtsp://cam/main"} = child(spec, :source)
      refute Map.has_key?(children, :demuxer)
      # No shared parser before the tee: `membrane_h26x` holds the last AU
      # until the next input, which would leak one old-session AU past the
      # session cut (P1-D13).
      refute Map.has_key?(children, :ingest_parser)

      # Same tagger, same tee, same branches — the ingest is the only difference.
      assert Enum.any?(links(spec), &match?(%{from: :source, to: :tagger}, &1))
      assert Enum.any?(links(spec), &match?(%{from: :tee, to: :picker}, &1))
    end

    test "no motion_json, no gate element — today's chain exactly" do
      spec = spec(detect: detect(stream_params: %{min_score: %{}}))

      refute Map.has_key?(children(spec), :motion_gate)
      assert Enum.any?(links(spec), &match?(%{from: :decoder, to: :infer}, &1))
    end

    test "an enabled motion_json puts the gate between decoder and inference" do
      params = %{min_score: %{}, motion_json: ~s({"enabled":true,"threshold":30})}
      spec = spec(detect: detect(stream_params: params, sample_fps: 5))
      links = links(spec)

      # The measurement is the element's (D-C3): the decoder is told nothing
      # about motion, while inference keeps the full params — the gate
      # *policy* still lives with the model session and reads these knobs.
      assert child(spec, :decoder).stream_params.motion_json == nil
      assert child(spec, :infer).stream_params.motion_json == params.motion_json

      assert %Cairn.Pipeline.MotionGate{
               config: %Cairn.Motion.Config{enabled: true, threshold: 30},
               sample_fps: 5
             } = child(spec, :motion_gate)

      # The same one-frame seam on both sides of the gate.
      for {from, to} <- [{:decoder, :motion_gate}, {:motion_gate, :infer}] do
        assert %{to_pad_props: props} = Enum.find(links, &match?(%{from: ^from, to: ^to}, &1)),
               "no #{from} -> #{to} link"

        assert props.target_queue_size == 1
        assert props.min_demand_factor == 0.5
      end

      refute Enum.any?(links, &match?(%{from: :decoder, to: :infer}, &1))
    end

    test "an enabled gate without a sample rate refuses to guess the calibration window" do
      params = %{min_score: %{}, motion_json: ~s({"enabled":true})}

      assert_raise KeyError, fn ->
        spec(detect: detect(stream_params: params))
      end
    end

    test "a malformed motion_json is a build error the operator can read" do
      params = %{min_score: %{}, motion_json: ~s({"treshold":30})}

      assert_raise ArgumentError, ~r/cam: motion_json: unknown motion knob/, fn ->
        spec(detect: detect(stream_params: params, sample_fps: 5))
      end
    end
  end

  describe "the owner's messages" do
    test "a reload's policy is forwarded to the sink, the only child that holds one" do
      {_actions, state} = init(detect: detect())
      camera = %Camera{id: "cam", record: %{"person" => %{min_score: 0.9}}}
      policy = Map.put(@policy, :record, camera.record)

      assert {[notify_child: {:detect, {:policy, ^camera, ^policy}}], _state} =
               Pipeline.handle_info({:policy, camera, policy}, %{}, state)
    end

    test "a policy is dropped for a camera whose detect branch was never built" do
      {_actions, state} = init([])

      assert {[], ^state} =
               Pipeline.handle_info({:policy, %Camera{id: "cam"}, @policy}, %{}, state)
    end

    test "a stats request only goes out while there is a branch to ask" do
      {_actions, detecting} = init(detect: detect())
      {_actions, plain} = init([])

      assert {[notify_child: {:detect, :stats}], _state} =
               Pipeline.handle_info(:detect_stats, %{}, detecting)

      assert {[], ^plain} = Pipeline.handle_info(:detect_stats, %{}, plain)
    end

    test "a flush ends the source's stream, which is what carries the muxer's tail out" do
      {_actions, state} = init([])

      assert {[notify_child: {:source, :eos}], ^state} =
               Pipeline.handle_info(:flush, %{}, state)
    end
  end

  describe "the tee's consumers" do
    test "none of them takes its input on a manual pad" do
      spec = spec(detect: detect())
      children = children(spec)
      consumers = for %{from: :tee, to: to, to_pad: pad} <- links(spec), do: {to, pad}

      assert length(consumers) == 3

      for {child, pad} <- consumers do
        # A manual input behind our push source arms membrane_core's toilet,
        # which kills the receiver ~200 buffers in. The only manual pads in
        # this graph are internal to the detect branch.
        refute flow_control(children[child], pad) == :manual
      end
    end
  end

  describe "what PipelineOwner hands the pipeline" do
    setup do
      Process.register(self(), :camera_test_probe)
      :ok
    end

    test "no plugin, no detect branch" do
      start_owner(camera("cam_none", nil))

      assert_receive {:pipeline_opts, opts}, 5_000
      assert opts[:detect] == nil
      assert opts[:initial_reason] == :started
    end

    test "the camera's wire floor, and no rate: the engine's profile carries that" do
      camera = %{camera("cam_group", {:group, "g"}) | min_score: %{"person" => 0.6}}
      start_owner(camera, config(camera))

      assert_receive {:pipeline_opts, opts}, 5_000
      refute Keyword.has_key?(opts[:detect], :sample_fps)
      assert opts[:detect][:stream_params] == %{min_score: %{"person" => 0.6}}
    end

    test "the camera and the policy the dispatch seam attaches" do
      camera = %{camera("cam_policy", {:group, "g"}) | post_window_seconds: 42}
      config = config(camera)
      start_owner(camera, config)

      assert_receive {:pipeline_opts, opts}, 5_000
      # resolved here rather than in the sink, and resolved identically to the
      # plugin ports' — same function, same arguments
      assert opts[:camera] == camera
      assert opts[:detect][:policy] == Config.policy(config, camera)
      assert opts[:detect][:policy].post == 42
    end

    defp camera(id, plugin) do
      %Camera{
        id: id,
        rtsp_url: "rtsp://127.0.0.1:554/x",
        plugin: plugin
      }
    end

    defp config(camera) do
      %Config{
        data_dir: "tmp/camera_test",
        plugin_groups: [
          %PluginGroup{
            name: "g",
            profile: %Profile{name: "p", sample_fps: 3}
          }
        ],
        cameras: [camera]
      }
    end

    defp start_owner(camera, config \\ %Config{data_dir: "tmp/camera_test"}) do
      start_supervised!(
        {Cairn.PipelineOwner,
         camera: camera,
         config: config,
         pipeline_module: RecordingPipeline,
         flush_grace_ms: 10,
         status_fun: fn _id, _status -> :ok end},
        id: {:owner, camera.id}
      )
    end
  end
end
