defmodule Cairn.PadReplayCore do
  @moduledoc """
  A `Membrane.MOTTracker.Core` that *is* a `Membrane.MOTTracker` element,
  driven through its pads.

  `Cairn.MotBench.drive/4` drives a core over a frame sequence and
  canonicalizes the identities it mints. Handing it this replays the same
  sequence through real pads under the same loop, the same context and the same
  canonicalization — so a run through the element and a run through the core it
  hosts differ by the element and by nothing else, which is the only way
  comparing their prediction files means anything.

  `:hosts` is the core the element itself hosts, in `Membrane.MOTTracker`'s own
  `tracker:` shape.
  """

  @behaviour Membrane.MOTTracker.Core

  import ExUnit.Assertions
  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  alias Cairn.ScriptedSource
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
          child(:source, ScriptedSource)
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

  # The replay loop calls none of these, and an element driven through its pads
  # would not answer them here anyway: the cut and the sweep are the element's
  # own, not something a core wrapper can stand in for.
  @impl true
  def suspend(_state, _max_suspended, _cut_ms), do: raise("the replay drives track/3 only")

  @impl true
  def expire_suspended(_state, _at_ms), do: raise("the replay drives track/3 only")

  @impl true
  def end_all(_state, _reason), do: raise("the replay drives track/3 only")

  @impl true
  def checkpoint_tracks(_state), do: raise("the replay drives track/3 only")
end
