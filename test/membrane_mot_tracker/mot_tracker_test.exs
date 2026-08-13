defmodule Membrane.MOTTrackerTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  alias Membrane.Buffer
  alias Membrane.MOTTracker.Event.EndAll
  alias Membrane.MOTTracker.Format
  alias Membrane.Testing

  # Returns whatever actions the test hands it, so a batch — or a buffer that
  # breaks the metadata contract — can be scripted exactly.
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

  # A core whose every output is a function of how many objects it has ever
  # been given, so carried state is visible from outside and nothing about the
  # element's own behaviour depends on real tracking.
  defmodule CountingCore do
    @moduledoc false
    @behaviour Membrane.MOTTracker.Core

    @impl true
    def new(opts), do: %{seen: 0, prefix: Keyword.get(opts, :prefix, "T")}

    @impl true
    def track(state, objects, context) do
      {tagged, seen} =
        Enum.map_reduce(objects, state.seen, fn object, seen ->
          {Map.put(object, :object_id, "#{state.prefix}#{seen + 1}"), seen + 1}
        end)

      {%{state | seen: seen}, tagged, [{:updated, %{seen: seen, at_ms: context.at_ms}}]}
    end

    @impl true
    def suspend(state, _max_suspended, _cut_ms),
      do: {state, [], %{suspended: 0, ended: 0, at: nil}}

    @impl true
    def expire_suspended(state, _at_ms), do: {state, []}

    @impl true
    def end_all(state, reason), do: {%{state | seen: 0}, [{:ended, %{reason: reason}}]}

    @impl true
    def checkpoint_tracks(state), do: [%{object_id: "#{state.prefix}#{state.seen}"}]
  end

  # Every call the element makes, in order, to the test that started it — the
  # lifecycle is orchestration and orchestration is only observable as a
  # sequence. Returns are fixed and recognisable rather than realistic: what a
  # core does with a cut is the core's own tests' business.
  defmodule RecordingCore do
    @moduledoc false
    @behaviour Membrane.MOTTracker.Core

    # Short enough that a test can sit through the element's sweep (this plus
    # its slack), and nothing like a real window.
    @adoption_window_ms 20

    @impl true
    def new(opts), do: %{owner: Keyword.fetch!(opts, :owner)}

    @impl true
    def track(state, objects, context) do
      record(state, {:track, objects, context.at_ms})
      {state, objects, [{:updated, %{at_ms: context.at_ms}}]}
    end

    @impl true
    def suspend(state, max_suspended, cut_ms) do
      record(state, {:suspend, max_suspended, cut_ms})
      {state, [{:ended, %{severed_at: cut_ms}}], %{suspended: 2, ended: 1, at: cut_ms}}
    end

    @impl true
    def expire_suspended(state, at_ms) do
      record(state, {:expire_suspended, at_ms})
      {state, [{:ended, %{expired_at: at_ms}}]}
    end

    @impl true
    def end_all(state, reason) do
      record(state, {:end_all, reason})
      {state, [{:ended, %{reason: reason}}]}
    end

    @impl true
    def checkpoint_tracks(_state), do: [%{object_id: "recorded"}]

    @impl true
    def adoption_window_ms, do: @adoption_window_ms

    defp record(state, call), do: send(state.owner, {:core, call})
  end

  # The same recorder without the optional callback: a core that declares by
  # omission that it keeps nothing adoptable.
  defmodule WindowlessCore do
    @moduledoc false
    @behaviour Membrane.MOTTracker.Core

    @impl true
    defdelegate new(opts), to: RecordingCore
    @impl true
    defdelegate track(state, objects, context), to: RecordingCore
    @impl true
    defdelegate suspend(state, max_suspended, cut_ms), to: RecordingCore
    @impl true
    defdelegate expire_suspended(state, at_ms), to: RecordingCore
    @impl true
    defdelegate end_all(state, reason), to: RecordingCore
    @impl true
    defdelegate checkpoint_tracks(state), to: RecordingCore
  end

  setup do
    %{pipeline: start_pipeline({CountingCore, prefix: "T"})}
  end

  defp start_pipeline(tracker, opts \\ []) do
    element = struct!(%Membrane.MOTTracker{tracker: tracker}, opts)

    pipeline =
      Testing.Pipeline.start_link_supervised!(
        spec: [
          child(:source, ScriptSource)
          |> child(:tracker, element)
          |> child(:sink, Testing.Sink)
        ]
      )

    Testing.Pipeline.notify_child(pipeline, :source,
      stream_format: {:output, %Format.Observations{}}
    )

    on_exit(fn -> Testing.Pipeline.terminate(pipeline) end)

    pipeline
  end

  # Mailbox order, which is the element's call order: `assert_receive` with an
  # unbound call matches the oldest message, so a sequence collected this way
  # is the sequence that happened.
  defp calls(count, timeout \\ 500) do
    Enum.map(1..count, fn _ ->
      assert_receive {:core, call}, timeout
      call
    end)
  end

  # The stop, in-band on the element's own input pad — where the stamper puts
  # it in production.
  defp end_all(pipeline, reason \\ :stream_reset) do
    Testing.Pipeline.notify_child(pipeline, :source, event: {:output, %EndAll{reason: reason}})
  end

  defp batch(pipeline, metadata, pts \\ 0) do
    Testing.Pipeline.notify_child(pipeline, :source,
      buffer: {:output, %Buffer{payload: <<>>, pts: pts, metadata: metadata}}
    )
  end

  defp observations(labels, at_ms, epoch) do
    %{
      objects: Enum.map(labels, &%{label: &1}),
      context: %{at_ms: at_ms, max_unseen_ms: 3_000},
      at_ms: at_ms,
      epoch: epoch
    }
  end

  test "the output format is emitted before any batch", %{pipeline: pipeline} do
    assert_sink_stream_format(pipeline, :sink, %Format.Tracks{})
  end

  test "a batch goes through the core and its result rides the out buffer",
       %{pipeline: pipeline} do
    batch(pipeline, observations(["car", "person"], 1_000, "epoch_one"))

    assert_sink_buffer(pipeline, :sink, %Buffer{metadata: metadata})

    assert %{
             tagged: [%{label: "car", object_id: "T1"}, %{label: "person", object_id: "T2"}],
             events: [{:updated, %{seen: 2, at_ms: 1_000}}],
             snapshot: [%{object_id: "T2"}],
             epoch: "epoch_one"
           } = metadata

    # …and the context it was tracked with, echoed: the host consumer is in
    # another process from the producer that built it, and pairing a result
    # with its batch is what it needs it for.
    assert %{at_ms: 1_000, max_unseen_ms: 3_000} = metadata.context
  end

  test "core state carries across batches", %{pipeline: pipeline} do
    batch(pipeline, observations(["car"], 1_000, "epoch_one"))
    assert_sink_buffer(pipeline, :sink, %Buffer{metadata: %{tagged: [%{object_id: "T1"}]}})

    batch(pipeline, observations(["car"], 1_500, "epoch_one"), 1)

    assert_sink_buffer(pipeline, :sink, %Buffer{metadata: metadata})
    assert %{tagged: [%{object_id: "T2"}], snapshot: [%{object_id: "T2"}]} = metadata
  end

  test "the epoch is the buffer's, not the last one seen", %{pipeline: pipeline} do
    batch(pipeline, observations(["car"], 1_000, "epoch_one"))
    assert_sink_buffer(pipeline, :sink, %Buffer{metadata: %{epoch: "epoch_one"}})

    batch(pipeline, observations(["car"], 2_000, "epoch_two"), 1)
    assert_sink_buffer(pipeline, :sink, %Buffer{metadata: %{epoch: "epoch_two"}})
  end

  test "a buffer without the metadata contract is dropped and counted",
       %{pipeline: pipeline} do
    batch(pipeline, %{objects: [%{label: "car"}], epoch: "epoch_one"})

    # Sequenced on the good batch that follows it: the drop emits nothing, so
    # its arrival is only observable once something behind it comes out.
    batch(pipeline, observations(["car"], 1_000, "epoch_one"), 1)
    assert_sink_buffer(pipeline, :sink, %Buffer{metadata: %{tagged: [%{object_id: "T1"}]}})

    Testing.Pipeline.notify_child(pipeline, :tracker, :stats)
    assert_pipeline_notified(pipeline, :tracker, {:stats, %{processed: 1, dropped: 1}})
  end

  # Present keys with broken values are the same violation: a nil epoch would
  # silently disable cut detection while still advancing the core.
  test "a buffer whose epoch or at_ms is broken is dropped, not tracked",
       %{pipeline: pipeline} do
    batch(pipeline, %{observations(["car"], 1_000, "epoch_one") | epoch: nil})
    batch(pipeline, %{observations(["car"], 1_500, "epoch_one") | at_ms: nil})

    batch(pipeline, observations(["car"], 2_000, "epoch_one"), 1)
    assert_sink_buffer(pipeline, :sink, %Buffer{metadata: %{tagged: [%{object_id: "T1"}]}})

    Testing.Pipeline.notify_child(pipeline, :tracker, :stats)
    assert_pipeline_notified(pipeline, :tracker, {:stats, %{processed: 1, dropped: 2}})
  end

  # The core reads the batch's instant off the context and the element reads it
  # beside the context; one clock read, written twice. A context missing it
  # would crash a core on its first bound, and one disagreeing with the element
  # would put the cut and the association on two clocks.
  test "a context that does not carry the element's own at_ms is dropped",
       %{pipeline: pipeline} do
    good = observations(["car"], 1_000, "epoch_one")

    batch(pipeline, %{good | context: %{max_unseen_ms: 3_000}})
    batch(pipeline, %{good | context: %{good.context | at_ms: "1000"}})
    batch(pipeline, %{good | context: %{good.context | at_ms: 999}})

    batch(pipeline, observations(["car"], 2_000, "epoch_one"), 1)
    assert_sink_buffer(pipeline, :sink, %Buffer{metadata: %{tagged: [%{object_id: "T1"}]}})

    Testing.Pipeline.notify_child(pipeline, :tracker, :stats)
    assert_pipeline_notified(pipeline, :tracker, {:stats, %{processed: 1, dropped: 3}})
  end

  describe "the session lifecycle" do
    setup do
      %{pipeline: start_pipeline({RecordingCore, owner: self()}, max_suspended: 4)}
    end

    # The element's slack over the core's window (`sweep_at/1`): the tick lands
    # past the window rather than on it, and the instant it sweeps with says so.
    @slack_ms 1_000

    test "an epoch change suspends the live tracks before the new batch is tracked",
         %{pipeline: pipeline} do
      batch(pipeline, observations(["car"], 1_000, "epoch_one"))
      assert calls(1) == [{:track, [%{label: "car"}], 1_000}]

      batch(pipeline, observations(["car"], 5_000, "epoch_two"), 1)

      assert calls(2) == [
               {:suspend, 4, 5_000},
               {:track, [%{label: "car"}], 5_000}
             ]
    end

    test "the cut's finals and its report ride the boundary buffer",
         %{pipeline: pipeline} do
      batch(pipeline, observations(["car"], 1_000, "epoch_one"))
      assert_sink_buffer(pipeline, :sink, %Buffer{metadata: %{suspension: nil}})

      batch(pipeline, observations(["car"], 5_000, "epoch_two"), 1)

      assert_sink_buffer(pipeline, :sink, %Buffer{metadata: metadata})

      assert %{
               tagged: [%{label: "car"}],
               events: [{:ended, %{severed_at: 5_000}}, {:updated, %{at_ms: 5_000}}],
               suspension: %{suspended: 2, ended: 1, at: 5_000},
               epoch: "epoch_two"
             } = metadata
    end

    test "the first epoch seen is not a boundary", %{pipeline: pipeline} do
      batch(pipeline, observations(["car"], 1_000, "epoch_one"))

      assert calls(1) == [{:track, [%{label: "car"}], 1_000}]
      refute_received {:core, {:suspend, _max, _cut}}
    end

    test "the same epoch announced again crosses nothing", %{pipeline: pipeline} do
      batch(pipeline, observations(["car"], 1_000, "epoch_one"))
      batch(pipeline, observations(["car"], 1_500, "epoch_one"), 1)

      assert calls(2) == [
               {:track, [%{label: "car"}], 1_000},
               {:track, [%{label: "car"}], 1_500}
             ]

      refute_received {:core, {:suspend, _max, _cut}}
    end

    test "a suspension expires on the element's own timer, with no further input",
         %{pipeline: pipeline} do
      batch(pipeline, observations(["car"], 1_000, "epoch_one"))
      batch(pipeline, observations(["car"], 5_000, "epoch_two"), 1)
      assert [{:track, _, 1_000}, {:suspend, 4, 5_000}, {:track, _, 5_000}] = calls(3)

      # The cut plus what the element waited, which is the whole of the clock it
      # has: nothing upstream stamped anything after the stream went down.
      expected = 5_000 + RecordingCore.adoption_window_ms() + @slack_ms
      assert calls(1, 2_000) == [{:expire_suspended, expected}]

      # Two buffers so far, so the third is the sweep's own.
      assert_sink_buffer(pipeline, :sink, %Buffer{})
      assert_sink_buffer(pipeline, :sink, %Buffer{})
      assert_sink_buffer(pipeline, :sink, %Buffer{metadata: metadata})

      assert %{
               tagged: [],
               events: [{:ended, %{expired_at: ^expected}}],
               suspension: nil,
               snapshot: [%{object_id: "recorded"}],
               epoch: "epoch_two"
             } = metadata

      # One sweep per cut: the tick collected every suspension the last cut
      # made, so a re-arm would only ever find nothing.
      refute_receive {:core, {:expire_suspended, _at}}, 1_200
    end

    # Its own pipeline: the core under test is the one the describe's setup
    # does not build.
    test "a core with no adoption window is armed no timer" do
      pipeline = start_pipeline({WindowlessCore, owner: self()})

      batch(pipeline, observations(["car"], 1_000, "epoch_one"))
      batch(pipeline, observations(["car"], 5_000, "epoch_two"), 1)
      assert [{:track, _, 1_000}, {:suspend, 128, 5_000}, {:track, _, 5_000}] = calls(3)

      refute_receive {:core, {:expire_suspended, _at}}, 1_200
    end

    test "the EndAll event ends everything, on a buffer of its own",
         %{pipeline: pipeline} do
      batch(pipeline, observations(["car"], 1_000, "epoch_one"))
      assert_sink_buffer(pipeline, :sink, %Buffer{metadata: %{tagged: [%{label: "car"}]}})

      end_all(pipeline)

      assert calls(2) == [{:track, [%{label: "car"}], 1_000}, {:end_all, :stream_reset}]
      assert_sink_buffer(pipeline, :sink, %Buffer{metadata: metadata})

      assert %{
               tagged: [],
               events: [{:ended, %{reason: :stream_reset}}],
               epoch: "epoch_one"
             } = metadata
    end

    test "a stop may name its own reason", %{pipeline: pipeline} do
      # The stamper's, when detection is turned off at runtime: what those
      # tracks ended of is not what a stream boundary would have ended them of.
      batch(pipeline, observations(["car"], 1_000, "epoch_one"))
      assert_sink_buffer(pipeline, :sink, %Buffer{metadata: %{tagged: [%{label: "car"}]}})

      end_all(pipeline, :detection_disabled)

      assert_sink_buffer(pipeline, :sink, %Buffer{metadata: metadata})
      assert %{events: [{:ended, %{reason: :detection_disabled}}], context: nil} = metadata
    end

    # The reason the stop is an event and not a parent notification: a producer
    # that ends its tracks and resumes in the same breath — the stamper, when
    # detection is flipped off and straight back on — has both halves on one
    # pad, so the ending can only ever be applied before what follows it. Out
    # of band the ending takes the parent hop and can arrive *after* the
    # resumed batch, ending the tracks that batch just minted.
    test "a stop cannot overtake the batches behind it", %{pipeline: pipeline} do
      batch(pipeline, observations(["car"], 1_000, "epoch_one"))
      assert_sink_buffer(pipeline, :sink, %Buffer{metadata: %{tagged: [%{label: "car"}]}})

      # One action list, so the two leave the source back to back and only the
      # pad decides how they arrive.
      Testing.Pipeline.notify_child(pipeline, :source,
        event: {:output, %EndAll{reason: :detection_disabled}},
        buffer:
          {:output,
           %Buffer{payload: <<>>, pts: 1, metadata: observations(["person"], 2_000, "epoch_one")}}
      )

      # The ending is applied first, so what the resumed batch mints is minted
      # after it and nothing ends that.
      assert calls(3) == [
               {:track, [%{label: "car"}], 1_000},
               {:end_all, :detection_disabled},
               {:track, [%{label: "person"}], 2_000}
             ]

      assert_sink_buffer(pipeline, :sink, %Buffer{
        metadata: %{tagged: [], events: [{:ended, %{reason: :detection_disabled}}]}
      })

      assert_sink_buffer(pipeline, :sink, %Buffer{metadata: %{tagged: [%{label: "person"}]}})
    end

    test "end of stream ends everything and is forwarded", %{pipeline: pipeline} do
      batch(pipeline, observations(["car"], 1_000, "epoch_one"))
      assert_sink_buffer(pipeline, :sink, %Buffer{metadata: %{tagged: [%{label: "car"}]}})

      Testing.Pipeline.notify_child(pipeline, :source, end_of_stream: :output)

      assert calls(2) == [{:track, [%{label: "car"}], 1_000}, {:end_all, :stream_reset}]
      assert_sink_buffer(pipeline, :sink, %Buffer{metadata: %{events: [{:ended, _final}]}})
      assert_end_of_stream(pipeline, :sink)
    end
  end

  test "a module that does not implement the behaviour is refused at init" do
    assert_raise ArgumentError, ~r/does not implement/, fn ->
      Membrane.MOTTracker.handle_init(%{}, %Membrane.MOTTracker{tracker: {__MODULE__, []}})
    end
  end
end
