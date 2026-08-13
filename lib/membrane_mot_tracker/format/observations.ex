defmodule Membrane.MOTTracker.Format.Observations do
  @moduledoc """
  What `Membrane.MOTTracker` consumes: one batch of detections per buffer.

  A struct with no fields. Everything that varies rides the buffers, and the
  format exists so a pad can declare what it accepts — there is no ecosystem
  convention for a detections pad to defer to.

  `payload` is empty; `metadata` carries:

    * `:objects` — the batch, in the core's object vocabulary.
    * `:context` — the resolved per-batch policy, `at_ms` included
      (`t:Membrane.MOTTracker.Core.context/0`).
    * `:at_ms` — the batch's instant on the tracking clock, beside the context
      so the element can time its own work without reading into a map that is
      the core's to interpret.
    * `:epoch` — which stream session these observations belong to.

  The clock is the producer's: `at_ms` is stamped where the frame was
  observed, never read from a clock inside this element, so a batch delayed by
  slow inference is still dated when it was seen. A buffer missing any of these
  keys is dropped and counted.
  """
  defstruct []
end
