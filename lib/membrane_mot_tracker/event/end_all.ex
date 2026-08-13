defmodule Membrane.MOTTracker.Event.EndAll do
  @moduledoc """
  In-band order to `Membrane.MOTTracker`: end every track you are still
  holding, under `reason`, and emit their finals.

  In-band rather than a parent notification because it is a *transition* on
  the same stream the batches ride — a producer that stops sending (detection
  turned off) and then starts again must have the ending land between the two
  sides of its own gate. Out of band it races them: the notification takes the
  parent hop while the resumed batches go straight down the pad, so a fast
  off→on flip can end the tracks the resumed batches just minted.

  `reason` reaches the core untouched and becomes every ended track's end
  reason. The default is the one the element gives a stop that names none.
  """

  @derive Membrane.EventProtocol
  defstruct reason: :stream_reset

  @type t :: %__MODULE__{reason: atom()}
end
