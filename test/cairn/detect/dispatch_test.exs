defmodule Cairn.Detect.DispatchTest do
  # No tracker is started: the seam's contract is which cast goes where, and
  # `Cairn.CameraTrackerTest` owns what the tracker then does with it.
  use ExUnit.Case, async: true

  alias Cairn.Config.Camera
  alias Cairn.Detect.Dispatch
  alias Cairn.Observation

  # The two tiers, both present and disagreeing: `record:` excludes the label
  # `track:` admits. Anything that read or rewrote the policy on the way through
  # would have to collapse them.
  @policy %{
    pre: 5,
    post: 10,
    max: 300,
    track: %{"person" => %{min_score: 0.4}, "cat" => %{min_score: 0.5}},
    record: %{"person" => %{min_score: 0.6}}
  }

  setup do
    id = "disp_#{System.unique_integer([:positive])}"
    %{camera: %Camera{id: id, rtsp_url: "rtsp://h/1"}, camera_id: id}
  end

  defp observation(pts) do
    %Observation{camera_id: "unset", pts: pts, at_ms: pts / 90.0, objects: [], protocol: :v1}
  end

  describe "forward/4" do
    test "hands the tracker the camera, the policy and the observation, unread", ctx do
      camera = ctx.camera
      observation = observation(90_000)

      assert :ok = Dispatch.forward(camera, @policy, observation, tracker: self())

      assert_received {:"$gen_cast", {:detections, ^camera, policy, ^observation}}
      assert policy == @policy
      # both tiers arrive whole, and neither moved the other
      assert policy.track == @policy.track
      assert policy.record == @policy.record
    end

    test "with no tracker named, routes to the camera's own tracker", ctx do
      # `Cairn.CameraTracker.ensure/1` resolves the registry before it starts
      # anything, so standing in under the camera's own key is the production
      # path minus the tracker's body.
      {:ok, _} = Registry.register(Cairn.Registry, {ctx.camera_id, :camera_tracker}, nil)

      assert :ok = Dispatch.forward(ctx.camera, @policy, observation(90_000))

      camera = ctx.camera
      assert_received {:"$gen_cast", {:detections, ^camera, @policy, %Observation{}}}
    end
  end

  describe "forward_all/4" do
    test "delivers one push's frames in order", ctx do
      observations = Enum.map([90_000, 93_000, 96_000], &observation/1)

      assert :ok = Dispatch.forward_all(ctx.camera, @policy, observations, tracker: self())

      for %Observation{pts: pts} <- observations do
        assert_received {:"$gen_cast", {:detections, _camera, _policy, %Observation{pts: ^pts}}}
      end

      refute_received {:"$gen_cast", {:detections, _camera, _policy, _observation}}
    end

    test "an empty push casts nothing", ctx do
      assert :ok = Dispatch.forward_all(ctx.camera, @policy, [], tracker: self())
      refute_received {:"$gen_cast", _message}
    end
  end

  describe "the one seam" do
    # Compiled call sites, so a producer that grew a second route to the tracker
    # fails here rather than in whichever tier test its policy stopped reaching.
    defp calls(module) do
      {:ok, {^module, [imports: imports]}} = :beam_lib.chunks(:code.which(module), [:imports])
      MapSet.new(imports, fn {called, _fun, _arity} -> called end)
    end

    test "every producer routes through it, and none reaches the tracker itself" do
      for producer <- [Cairn.PluginPort, Cairn.PluginGroupPort, Cairn.Pipeline.InferSink] do
        assert Dispatch in calls(producer), "#{inspect(producer)} does not use the seam"

        refute Cairn.CameraTracker in calls(producer),
               "#{inspect(producer)} calls the tracker around the seam"
      end

      assert Cairn.CameraTracker in calls(Dispatch)
    end
  end
end
