defmodule Cairn.Pipeline.CameraTest do
  # The FFmpegPort case spawns a real (sleeping) OS process and a pipeline.
  use ExUnit.Case, async: false

  alias Cairn.Config
  alias Cairn.Config.{Camera, PluginGroup, Profile}
  alias Cairn.Pipeline.Camera, as: Pipeline

  defmodule RecordingPipeline do
    @moduledoc false
    use Membrane.Pipeline

    # `owner:` is the port, not the test, so the probe is registered by name.
    @impl true
    def handle_init(_ctx, opts) do
      send(Process.whereis(:camera_test_probe), {:pipeline_opts, opts})
      {[], %{}}
    end
  end

  @policy %{pre: 5, post: 10, max: 300, track: nil, record: nil}

  defp init(opts) do
    Pipeline.handle_init(
      %{},
      Keyword.merge([camera: %Camera{id: "cam"}, epoch: "epoch", owner: self()], opts)
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

  defp flow_control(module, pad) do
    # A bin's pads carry no flow control at all, which is itself the answer:
    # `:manual` is not expressible there.
    Map.get(module.membrane_pads()[pad], :flow_control, :bin)
  end

  describe "the detect branch" do
    test "is not built for a camera with no plugin configured" do
      children = children(spec([]))

      refute Map.has_key?(children, :picker)
      refute Map.has_key?(children, :infer)
      assert Map.has_key?(children, :ring_sink)
    end

    test "hangs off the tee: picker, then decoder, then the sink" do
      spec = spec(detect: detect())
      links = links(spec)

      assert Enum.any?(links, &match?(%{from: :tee, to: :picker}, &1))

      # One AU in flight into the decoder, one sampled frame into the sink.
      for {from, to} <- [{:picker, :decoder}, {:decoder, :infer}] do
        assert %{to_pad_props: props} =
                 Enum.find(links, &match?(%{from: ^from, to: ^to}, &1)),
               "no #{from} -> #{to} link"

        assert props.target_queue_size == 1
        assert props.min_demand_factor == 0.5
      end
    end

    test "the picker takes no options — the decoder's gate owns the rate" do
      spec = spec(detect: detect())

      {_name, picker, _opts} =
        Enum.find_value(spec, &Enum.find(&1.children, fn {name, _d, _o} -> name == :picker end))

      assert picker == Cairn.Pipeline.Picker
    end

    test "the decoder and the sink share one stream_params, so the two native opens agree" do
      params = %{min_score: %{"person" => 0.6}}
      spec = spec(detect: detect(stream_params: params))

      {_name, decoder, _opts} =
        Enum.find_value(spec, &Enum.find(&1.children, fn {name, _d, _o} -> name == :decoder end))

      {_name, sink, _opts} =
        Enum.find_value(spec, &Enum.find(&1.children, fn {name, _d, _o} -> name == :infer end))

      assert %Cairn.Pipeline.Decoder{camera_id: "cam", stream_params: ^params} = decoder
      assert %Cairn.Pipeline.InferSink{stream_params: ^params} = sink
    end
  end

  describe "a reload's policy" do
    test "is forwarded to the sink, which is the only child that holds one" do
      {_actions, state} = init(detect: detect())
      camera = %Camera{id: "cam", record: %{"person" => %{min_score: 0.9}}}
      policy = Map.put(@policy, :record, camera.record)

      assert {[notify_child: {:infer, {:policy, ^camera, ^policy}}], _state} =
               Pipeline.handle_info({:policy, camera, policy}, %{}, state)
    end

    test "is dropped for a camera whose detect branch was never built" do
      {_actions, state} = init([])

      assert {[], ^state} =
               Pipeline.handle_info({:policy, %Camera{id: "cam"}, @policy}, %{}, state)
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
        # which kills the receiver ~200 buffers in. The only manual pad in this
        # graph is the internal picker -> infer seam.
        refute flow_control(children[child], pad) == :manual
      end
    end
  end

  describe "what FFmpegPort hands the pipeline" do
    setup do
      Process.register(self(), :camera_test_probe)
      :ok
    end

    test "no plugin, no detect branch" do
      start_port(camera("cam_none", nil))

      assert_receive {:pipeline_opts, opts}, 5_000
      assert opts[:detect] == nil
    end

    test "the camera's wire floor, and no rate: the engine's profile carries that" do
      camera = %{camera("cam_group", {:group, "g"}) | min_score: %{"person" => 0.6}}
      start_port(camera, config(camera))

      assert_receive {:pipeline_opts, opts}, 5_000
      refute Keyword.has_key?(opts[:detect], :sample_fps)
      assert opts[:detect][:stream_params] == %{min_score: %{"person" => 0.6}}
    end

    test "the camera and the policy the dispatch seam attaches" do
      camera = %{camera("cam_policy", {:group, "g"}) | post_window_seconds: 42}
      config = config(camera)
      start_port(camera, config)

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
        pipeline: :membrane,
        plugin: plugin
      }
    end

    defp config(camera) do
      %Config{
        data_dir: "tmp/camera_test",
        plugin_groups: [
          %PluginGroup{
            name: "g",
            command: ["cairn-detect"],
            profile: %Profile{name: "p", sample_fps: 3}
          }
        ],
        cameras: [camera]
      }
    end

    defp start_port(camera, config \\ %Config{data_dir: "tmp/camera_test"}) do
      start_supervised!(
        {Cairn.FFmpegPort,
         camera: camera,
         config: config,
         command: "sleep 5",
         pipeline_module: RecordingPipeline,
         status_fun: fn _id, _status -> :ok end},
        id: {:port, camera.id}
      )
    end
  end
end
