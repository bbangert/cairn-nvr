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

  defp init do
    {[], state} = Picker.handle_init(%{}, %{})
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

  # The decoder starts empty, so nothing is forwardable until an IDR has been.
  defp synced(state \\ nil) do
    {[], state} = feed(state || init(), @keyframe, 0)
    {[buffer: _idr], state} = demand(state)
    state
  end

  describe "what is eligible" do
    test "a non-keyframe AU is forwarded like any other" do
      {[], state} = demand(synced())
      assert {[buffer: {:output, %Buffer{pts: 1}}], state} = feed(state, @interframe, 1)
      assert state.emitted == 2
      assert state.dropped == 0
    end

    test "nothing is dropped while the sink keeps demanding" do
      state =
        Enum.reduce(1..20, synced(), fn pts, state ->
          {[], state} = demand(state)
          {[buffer: _one], state} = feed(state, @interframe, pts)
          state
        end)

      assert state.emitted == 21
      assert state.dropped == 0
    end

    test "nothing is forwarded before the first keyframe" do
      {[], state} = demand(init(), 10)
      {actions, state} = feed(state, @interframe, 1)

      assert actions == []
      assert state.pending == nil
      assert state.dropped == 1
    end

    test "there is nothing to configure — the crate owns the rate" do
      refute function_exported?(Picker, :__struct__, 0)
    end

    test "an AU with no pts is not a candidate, and is a hole like any other" do
      {[], state} = feed(synced(), @keyframe, nil)

      assert state.pending == nil
      assert state.dropped == 1
      assert state.expecting_keyframe?
    end
  end

  describe "the depth-1 slot" do
    test "nothing is emitted without demand" do
      assert {[], state} = feed(synced(), @interframe)
      assert state.pending != nil
    end

    test "the AU waiting is kept and the newer one dropped — it is the decodable one" do
      {[], state} = feed(synced(), @interframe, 1)
      {[], state} = feed(state, @interframe, 2)

      assert {[buffer: {:output, %Buffer{pts: 1}}], state} = demand(state)
      assert state.pending == nil
      assert state.dropped == 1
    end

    test "one demand emits one buffer and no more" do
      {[], state} = feed(synced(), @interframe, 1)
      {[buffer: _emitted], state} = demand(state)

      assert {[], _state} = demand(state)
    end

    test "unmet demand outlives the slot, so the next AU goes straight out" do
      {[], waiting} = demand(synced())
      assert {[buffer: {:output, %Buffer{pts: 3}}], _state} = feed(waiting, @interframe, 3)
    end
  end

  describe "the keyframe rule" do
    test "a waiting keyframe is never the one dropped" do
      {[], state} = feed(synced(), @keyframe, 1)
      {[], state} = feed(state, @interframe, 2)
      {[], state} = feed(state, @interframe, 3)

      assert state.pending.pts == 1
      assert state.dropped == 2

      # …and it is still the buffer the demand collects
      assert {[buffer: {:output, %Buffer{pts: 1}}], _state} = demand(state)
    end

    test "a keyframe displaces a waiting inter-frame" do
      {[], state} = feed(synced(), @interframe, 1)
      {[], state} = feed(state, @keyframe, 2)

      assert state.pending.pts == 2
      assert state.dropped == 1
    end

    test "a newer keyframe displaces a waiting one — the decoder resyncs on either" do
      {[], state} = feed(synced(), @keyframe, 1)
      {[], state} = feed(state, @keyframe, 2)

      assert state.pending.pts == 2
      assert state.dropped == 1
    end
  end

  describe "after a hole" do
    test "nothing is forwarded until the next keyframe" do
      {[], state} = feed(synced(), @interframe, 1)
      # no demand, so 2 is lost and the stream is holed from here
      {[], state} = feed(state, @interframe, 2)
      {[buffer: {:output, %Buffer{pts: 1}}], state} = demand(state)

      # every inter-frame after the hole would decode to concealment
      state =
        Enum.reduce(3..8, state, fn pts, state ->
          {[], state} = demand(state)
          {actions, state} = feed(state, @interframe, pts)
          assert actions == []
          state
        end)

      assert state.dropped == 7

      # …and the IDR ends it, on the demand still standing
      assert {[buffer: {:output, %Buffer{pts: 9}}], state} = feed(state, @keyframe, 9)
      refute state.expecting_keyframe?

      # …after which the stream is contiguous again
      {[], state} = demand(state)
      assert {[buffer: {:output, %Buffer{pts: 10}}], _state} = feed(state, @interframe, 10)
    end

    test "a keyframe dropped for want of pts does not end the wait" do
      {[], state} = feed(synced(), @interframe, 1)
      {[], state} = feed(state, @interframe, 2)
      {[buffer: _one], state} = demand(state)
      {[], state} = feed(state, @keyframe, nil)

      assert {[], state} = feed(state, @interframe, 3)
      assert state.expecting_keyframe?
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
      # A 15-frame GOP, so the flood is a stream and not an unforwardable run of
      # inter-frames.
      buffers =
        for pts <- 1..500,
            do: buffer(if(rem(pts, 15) == 1, do: @keyframe, else: @interframe), pts)

      pipeline =
        Testing.Pipeline.start_link_supervised!(
          spec: [
            child(:source, %Cairn.PushSource{buffers: buffers})
            |> child(:picker, Picker)
            |> via_in(:input, target_queue_size: 1, min_demand_factor: 0.5)
            |> child(:sink, OneShotSink)
          ]
        )

      # The wedged sink took one AU and its input queue holds the one more it was
      # sized for; everything after that had nowhere to go, and a `:manual` input
      # on the picker would have been killed by the toilet ~200 buffers in instead
      # of reporting this.
      Process.sleep(200)
      Testing.Pipeline.notify_child(pipeline, :picker, :stats)
      assert_pipeline_notified(pipeline, :picker, {:stats, stats}, 5_000)

      assert stats.emitted in 1..2
      assert stats.dropped >= 400
      assert stats.dropped + stats.emitted <= 500

      Testing.Pipeline.terminate(pipeline)
    end
  end
end
