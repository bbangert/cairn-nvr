defmodule Cairn.TrackerAdapterTest do
  @moduledoc """
  `Cairn.Tracker` as the core `Membrane.MOTTracker` hosts: the same identities
  and the same adoption across a cut, reached through the pads.

  The fixtures are `Cairn.TrackerTest`'s, deliberately — the boxes there are
  calibrated against the thresholds this exercises (`@shift_05` is IoU 0.778,
  well over the stitch floor), and a second set calibrated by this file would
  drift from them.
  """

  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  alias Cairn.{MotBench, Track, Tracker}
  alias Membrane.Buffer
  alias Membrane.MOTTracker.Format
  alias Membrane.Testing
  alias Mix.Tasks.Cairn.Mot.Track, as: Harness

  @box [0.0, 0.0, 0.4, 0.4]
  # IoU 0.778 with @box: over the adoption floor
  @shift_05 [0.05, 0.0, 0.4, 0.4]
  # IoU 1/3 with @box: under it, so it is nobody's identity
  @shift_2 [0.2, 0.0, 0.4, 0.4]
  @walker [0.30, 0.20, 0.10, 0.30]

  # The MOT harness's own committed sequence (180 frames, 2971 detections) —
  # a replay long enough that a divergence has somewhere to show itself.
  @sequence "test/fixtures/sparsetrack/synthetic"

  defmodule ScriptSource do
    @moduledoc false
    use Membrane.Source

    def_output_pad(:output, accepted_format: _any, flow_control: :push)

    @impl true
    def handle_init(_ctx, _opts), do: {[], %{}}

    @impl true
    def handle_parent_notification(actions, _ctx, state) when is_list(actions),
      do: {actions, state}
  end

  defp start_pipeline do
    pipeline =
      Testing.Pipeline.start_link_supervised!(
        spec: [
          child(:source, ScriptSource)
          |> child(:tracker, %Membrane.MOTTracker{tracker: {Tracker, []}})
          |> child(:sink, Testing.Sink)
        ]
      )

    Testing.Pipeline.notify_child(pipeline, :source,
      stream_format: {:output, %Format.Observations{}}
    )

    on_exit(fn -> Testing.Pipeline.terminate(pipeline) end)

    pipeline
  end

  describe "identities through the pads" do
    setup do
      %{pipeline: start_pipeline()}
    end

    defp det(label, bbox) do
      %{
        label: label,
        bbox: bbox,
        score: 0.9,
        track_id: nil,
        observation_kind: "detected"
      }
    end

    defp batch(pipeline, objects, at_ms, epoch) do
      metadata = %{
        objects: objects,
        context: %{
          camera_id: "cam_a",
          epoch: epoch,
          at_ms: at_ms,
          observed_at: DateTime.add(~U[2026-08-12 12:00:00Z], at_ms, :millisecond),
          max_unseen_ms: 3_000,
          max_live_tracks: 128,
          stationary_after_ms: 10_000
        },
        at_ms: at_ms,
        epoch: epoch
      }

      Testing.Pipeline.notify_child(pipeline, :source,
        buffer: {:output, %Buffer{payload: <<>>, pts: at_ms, metadata: metadata}}
      )
    end

    defp out(pipeline) do
      assert_sink_buffer(pipeline, :sink, %Buffer{metadata: metadata})
      metadata
    end

    test "two objects keep their identities across batches", %{pipeline: pipeline} do
      batch(pipeline, [det("car", @box), det("person", @walker)], 0, "epoch_one")
      assert %{tagged: [car, walker], suspension: nil} = out(pipeline)
      assert car.object_id != walker.object_id

      batch(pipeline, [det("car", @box), det("person", @walker)], 500, "epoch_one")
      assert %{tagged: [%{object_id: second_car}, %{object_id: second_walker}]} = out(pipeline)

      assert second_car == car.object_id
      assert second_walker == walker.object_id
    end

    test "an epoch change suspends, and an overlapping box in the new epoch resumes the id",
         %{pipeline: pipeline} do
      batch(pipeline, [det("car", @box)], 0, "epoch_one")
      assert %{tagged: [%{object_id: id}]} = out(pipeline)

      batch(pipeline, [det("car", @box)], 500, "epoch_one")
      assert %{snapshot: [%Track{object_id: ^id}]} = out(pipeline)

      batch(pipeline, [det("car", @shift_05)], 1_000, "epoch_two")
      metadata = out(pipeline)

      # Suspended, not ended: the cut severed nothing, and the box that follows
      # it took the identity back rather than minting beside it.
      assert %{suspended: 1, ended: 0} = metadata.suspension
      assert [%{object_id: ^id}] = metadata.tagged
      assert {:adopted, %Track{object_id: ^id}} = List.keyfind(metadata.events, :adopted, 0)
      assert [%Track{object_id: ^id}] = metadata.snapshot
    end

    test "a box the cut's suspension cannot claim mints its own identity",
         %{pipeline: pipeline} do
      batch(pipeline, [det("car", @box)], 0, "epoch_one")
      assert %{tagged: [%{object_id: id}]} = out(pipeline)

      batch(pipeline, [det("car", @shift_2)], 1_000, "epoch_two")
      metadata = out(pipeline)

      assert [%{object_id: other}] = metadata.tagged
      refute other == id
      # the suspension is still waiting for something that overlaps it
      assert %{suspended: 1, ended: 0} = metadata.suspension

      # Both still owe a final summary: the one that is waiting to be adopted and
      # the one that just minted. Compared as a set — two ULIDs minted inside one
      # millisecond order by their random half.
      assert Enum.sort(Enum.map(metadata.snapshot, & &1.object_id)) == Enum.sort([id, other])
    end

    test "a box the window has run out on mints instead, however well it overlaps",
         %{pipeline: pipeline} do
      batch(pipeline, [det("car", @box)], 0, "epoch_one")
      assert %{tagged: [%{object_id: id}]} = out(pipeline)

      # An empty frame is a real one, so the cut can be a batch of its own:
      # nothing here competes for the suspension, and the box that comes back
      # below is the identical one the adoption test resumes with.
      batch(pipeline, [], 1_000, "epoch_two")
      assert %{tagged: [], suspension: %{suspended: 1, ended: 0}} = out(pipeline)

      # One millisecond past the window, measured from the cut the suspension
      # was stamped with. The only difference from the resume test above is
      # this offset, so the window is what refuses it.
      batch(pipeline, [det("car", @box)], 1_000 + Tracker.adoption_window_ms() + 1, "epoch_two")
      metadata = out(pipeline)

      assert [%{object_id: other}] = metadata.tagged
      refute other == id
      assert List.keyfind(metadata.events, :adopted, 0) == nil

      # This buffer crossed no boundary, so no sweep is what ended the
      # suspension: the batch settled it on the way in, and its final rides the
      # batch that refused to adopt it. Nothing is owed for it afterwards.
      assert metadata.suspension == nil

      assert {:ended, %Track{object_id: ^id, end_reason: :stream_reset}} =
               List.keyfind(metadata.events, :ended, 0)

      assert Enum.map(metadata.snapshot, & &1.object_id) == [other]
    end
  end

  describe "an MOT replay" do
    # `Cairn.MotBench.drive/4` drives a `Membrane.MOTTracker.Core` over a frame
    # sequence and canonicalizes the identities it mints. Handing it a core that
    # *is* the element replays the same sequence through the pads under the same
    # loop, the same context and the same canonicalization — so the two runs
    # differ by the element and by nothing else, which is the only way the
    # comparison below means what it says.
    defmodule PadCore do
      @moduledoc false
      @behaviour Membrane.MOTTracker.Core

      import ExUnit.Assertions
      import Membrane.ChildrenSpec
      import Membrane.Testing.Assertions

      alias Cairn.TrackerAdapterTest.ScriptSource
      alias Membrane.Buffer
      alias Membrane.MOTTracker.Format
      alias Membrane.Testing

      # One epoch for the whole replay: a boundary is the suspend/adopt tests'
      # business, and a cut here would be a second thing under comparison.
      @epoch "replay"

      @impl true
      def new(opts) do
        pipeline =
          Testing.Pipeline.start_link_supervised!(
            spec: [
              child(:source, ScriptSource)
              |> child(:tracker, %Membrane.MOTTracker{tracker: Keyword.fetch!(opts, :hosts)})
              |> child(:sink, Testing.Sink)
            ]
          )

        Testing.Pipeline.notify_child(pipeline, :source,
          stream_format: {:output, %Format.Observations{}}
        )

        %{pipeline: pipeline, pts: 0}
      end

      @impl true
      def track(state, objects, context) do
        metadata = %{
          objects: objects,
          context: context,
          at_ms: context.at_ms,
          epoch: @epoch
        }

        Testing.Pipeline.notify_child(state.pipeline, :source,
          buffer: {:output, %Buffer{payload: <<>>, pts: state.pts, metadata: metadata}}
        )

        pipeline = state.pipeline
        assert_sink_buffer(pipeline, :sink, %Buffer{metadata: out})

        {%{state | pts: state.pts + 1}, out.tagged, out.events}
      end

      # The replay loop calls neither, and an element driven through its pads
      # would not answer them here anyway: the cut and the sweep are the
      # element's own, not something a core wrapper can stand in for.
      @impl true
      def suspend(_state, _max_suspended, _cut_ms), do: raise("the replay drives track/3 only")

      @impl true
      def expire_suspended(_state, _at_ms), do: raise("the replay drives track/3 only")

      @impl true
      def end_all(_state, _reason), do: raise("the replay drives track/3 only")

      @impl true
      def checkpoint_tracks(_state), do: raise("the replay drives track/3 only")
    end

    test "through the element's pads is identical to the same replay through the core" do
      frames = frames()
      policy = MotBench.policy([])

      {core_lines, core_emitted, core_minted} = MotBench.drive(frames, seqinfo(), policy)

      {pad_lines, pad_emitted, pad_minted} =
        MotBench.drive(frames, seqinfo(), policy, tracker: {PadCore, hosts: {Tracker, []}})

      # The whole prediction file, byte for byte: every frame's every box under
      # the identity the run gave it. The element neither dropped a batch, nor
      # reordered one, nor let a track through under a second identity.
      assert IO.iodata_to_binary(pad_lines) == IO.iodata_to_binary(core_lines)
      assert {pad_emitted, pad_minted} == {core_emitted, core_minted}

      # …and the sequence is a real workload rather than a handful of boxes two
      # empty runs would agree on.
      assert core_minted > 10
      assert core_emitted > 1_000
    end

    defp seqinfo, do: Harness.parse_seqinfo!(Path.join(@sequence, "seqinfo.ini"))

    defp frames do
      seqinfo = seqinfo()

      detections =
        [@sequence, "det", "det.txt"]
        |> Path.join()
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&Harness.parse_det_line!/1)
        |> Enum.group_by(& &1.frame, &Harness.object(&1, seqinfo, :normalized))
        # a box the frame clips to nothing is dropped, as the harness drops it
        |> Map.new(fn {frame, objects} -> {frame, Enum.reject(objects, &is_nil/1)} end)

      for frame <- 1..seqinfo.seq_length,
          do: {frame, Harness.at_ms(frame, seqinfo.frame_rate), Map.get(detections, frame, [])}
    end
  end
end
