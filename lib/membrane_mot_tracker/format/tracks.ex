defmodule Membrane.MOTTracker.Format.Tracks do
  @moduledoc """
  What `Membrane.MOTTracker` emits: one buffer per input buffer, plus the ones
  the element's own lifecycle produces (below). Empty payload, everything in
  `metadata`:

    * `:tagged` — this batch's objects carrying the identities the core
      assigned them; shorter than the input batch when the core refused one.
    * `:events` — the lifecycle transitions the batch caused
      (`t:Membrane.MOTTracker.Core.event/0`), in the order a consumer applies
      them. A buffer that crossed a stream boundary leads with the finals of
      the tracks that did not survive the cut.
    * `:suspension` — `t:Membrane.MOTTracker.Core.suspension/0` for a buffer
      that crossed a stream boundary, `nil` for every other: the link-health
      report of that cut, which no event carries.
    * `:snapshot` — `c:Membrane.MOTTracker.Core.checkpoint_tracks/1` taken
      after the batch: every track still owed a final summary. It rides every
      buffer because the alternative is asking the element for it, and a
      consumer that persists tracks needs it at exactly the moments it is
      already handling one of these.
    * `:epoch` — the input buffer's, carried rather than re-read from element
      state: it names the session these tracks were observed under.
    * `:context` — the input buffer's, echoed. A host consumer sits in another
      process from the producer that built it, so without this it would have to
      keep a shadow queue of what it sent in order to pair a result with the
      batch's own instants and thresholds. `nil` on the element's own buffers,
      which answer to no batch.

  The element emits a buffer of its own when a lifecycle event has no batch to
  ride: a suspension whose adoption window ran out with the stream still down,
  or a deliberate stop. It carries no `pts` and an empty `:tagged` — the events
  and the snapshot after them are the whole of it — and its `:epoch` is the
  last session seen, which is the one those tracks were observed under.
  """
  defstruct []
end
