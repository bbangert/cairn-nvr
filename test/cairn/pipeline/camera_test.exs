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

  defp spec(opts) do
    {[spec: spec], _state} =
      Pipeline.handle_init(
        %{},
        Keyword.merge([camera_id: "cam", epoch: "epoch", owner: self()], opts)
      )

    spec
  end

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

    test "hangs off the tee behind the picker, with the sink one hop further" do
      spec = spec(detect: [])
      links = links(spec)

      assert Enum.any?(links, &match?(%{from: :tee, to: :picker}, &1))
      assert %{to_pad_props: props} = Enum.find(links, &match?(%{from: :picker, to: :infer}, &1))
      assert props.target_queue_size == 1
      assert props.min_demand_factor == 0.5
    end

    test "carries the configured sample rate into the picker" do
      spec = spec(detect: [sample_fps: 3])

      {_name, picker, _opts} =
        Enum.find_value(spec, &Enum.find(&1.children, fn {name, _d, _o} -> name == :picker end))

      assert picker.sample_fps == 3
    end
  end

  describe "the tee's consumers" do
    test "none of them takes its input on a manual pad" do
      spec = spec(detect: [])
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

    test "a profiled group's sample rate and the camera's wire floor" do
      camera = %{camera("cam_group", {:group, "g"}) | min_score: %{"person" => 0.6}}
      start_port(camera, config(camera))

      assert_receive {:pipeline_opts, opts}, 5_000
      assert opts[:detect][:sample_fps] == 3
      assert opts[:detect][:stream_params] == %{min_score: %{"person" => 0.6}}
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
