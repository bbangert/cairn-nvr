defmodule Cairn.Pipeline.PickerTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  alias Cairn.Pipeline.Picker
  alias Membrane.Buffer
  alias Membrane.Testing

  # SPS, PPS, IDR slice — what a TS keyframe AU looks like to the NAL walk.
  @keyframe <<0, 0, 1, 0x67, 0x42, 0xC0, 0x1F, 0, 0, 1, 0x68, 0xCE, 0x3C, 0, 0, 1, 0x65, 0x88>>
  # AUD then a non-IDR slice.
  @interframe <<0, 0, 1, 0x09, 0x30, 0, 0, 1, 0x41, 0x9A, 0x02>>

  defp init(opts \\ []) do
    {[], state} = Picker.handle_init(%{}, struct(Picker, opts))
    state
  end

  defp buffer(payload, pts), do: %Buffer{payload: payload, pts: pts}

  defp feed(state, payload, pts \\ 0) do
    Picker.handle_buffer(:input, buffer(payload, pts), %{}, state)
  end

  defp demand(state, size \\ 1) do
    Picker.handle_demand(:output, size, :buffers, %{}, state)
  end

  describe "pad configuration" do
    test "the input is auto and only the output is manual" do
      pads = Picker.membrane_pads()

      assert pads[:input].flow_control == :auto
      assert pads[:output].flow_control == :manual
    end
  end

  describe "the depth-1 slot" do
    test "nothing is emitted without demand" do
      assert {[], state} = feed(init(), @keyframe)
      assert state.pending != nil
      assert state.emitted == 0
    end

    test "a second eligible AU replaces the one waiting — keep-newest, not oldest" do
      {[], state} = feed(init(), @keyframe, 1)
      {[], state} = feed(state, @keyframe, 2)

      assert {[buffer: {:output, %Buffer{pts: 2}}], state} = demand(state)
      assert state.pending == nil
      assert state.dropped == 1
      assert state.emitted == 1
    end

    test "one demand emits one buffer and no more" do
      {[], state} = feed(init(), @keyframe, 1)
      {[buffer: _emitted], state} = demand(state)

      assert {[], _state} = demand(state)
    end

    test "an ineligible AU costs the slot and the demand nothing" do
      {[], state} = feed(init(), @keyframe, 1)
      {[], with_inter} = feed(state, @interframe, 2)

      assert with_inter.pending == state.pending
      assert with_inter.dropped == state.dropped + 1

      # unmet demand outlives it, so the next eligible AU goes straight out
      {[], waiting} = demand(%{with_inter | pending: nil})
      assert {[buffer: {:output, %Buffer{pts: 3}}], _state} = feed(waiting, @keyframe, 3)
    end

    test "an AU with no pts is not a candidate" do
      {[], state} = feed(init(), @keyframe, nil)

      assert state.pending == nil
      assert state.dropped == 1
    end
  end

  describe "eligibility" do
    test "a non-keyframe AU is never emitted, however much demand there is" do
      {[], state} = demand(init(), 10)
      {actions, state} = feed(state, @interframe, 1)

      assert actions == []
      assert state.pending == nil
    end

    test "only_keyframes has no false setting to configure" do
      refute Map.has_key?(struct(Picker), :only_keyframes)
    end

    test "the sample gate is measured from the last emit" do
      {[], state} = feed(init(sample_fps: 1), @keyframe, 1)
      {[buffer: _emitted], state} = demand(state)

      # the next keyframe is inside the interval, so it is dropped rather than held
      {[], state} = feed(state, @keyframe, 2)
      assert state.pending == nil
      assert state.dropped == 1
    end

    test "the interval is the requested rate and nothing is added to it" do
      for fps <- [1, 5, 6, 30] do
        assert init(sample_fps: fps).interval_ms == ceil(1000 / fps)
      end
    end

    test "an AU exactly one interval after the last emit is due" do
      for fps <- [1, 5, 6, 30] do
        interval = ceil(1000 / fps)
        state = %{init(sample_fps: fps) | last_ms: System.monotonic_time(:millisecond) - interval}
        {[], fed} = feed(state, @keyframe, 1)

        assert fed.pending != nil,
               "at #{fps} fps an AU #{interval} ms after the last emit was dropped"
      end
    end
  end

  describe "under a push sender" do
    defmodule OneShotSink do
      @moduledoc false
      use Membrane.Sink

      def_input_pad(:input,
        accepted_format: %Membrane.H264{alignment: :au},
        flow_control: :manual,
        demand_unit: :buffers
      )

      @impl true
      def handle_init(_ctx, _opts), do: {[], %{}}

      @impl true
      def handle_playing(_ctx, state), do: {[demand: {:input, 1}], state}

      # Never demands again: the branch is wedged for the rest of the run.
      @impl true
      def handle_buffer(:input, _buffer, _ctx, state), do: {[], state}
    end

    @tag :capture_log
    test "the picker survives a flood past the toilet capacity and drops the surplus" do
      buffers = for pts <- 1..500, do: buffer(@keyframe, pts)

      pipeline =
        Testing.Pipeline.start_link_supervised!(
          spec: [
            child(:source, %Cairn.PushSource{buffers: buffers})
            |> child(:picker, %Picker{})
            |> via_in(:input, target_queue_size: 1, min_demand_factor: 0.5)
            |> child(:sink, OneShotSink)
          ]
        )

      # The wedged sink took one AU; everything after it had nowhere to go, and
      # a `:manual` input on the picker would have been killed by the toilet
      # ~200 buffers in instead of reporting this.
      Process.sleep(200)
      Testing.Pipeline.notify_child(pipeline, :picker, :stats)
      assert_pipeline_notified(pipeline, :picker, {:stats, stats}, 5_000)

      assert stats.emitted == 1
      assert stats.dropped >= 400
      assert stats.dropped + stats.emitted <= 500

      Testing.Pipeline.terminate(pipeline)
    end
  end
end
