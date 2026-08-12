defmodule Cairn.Pipeline.EpochChange do
  @moduledoc """
  In-band announcement of a freshly minted stream epoch, emitted by
  `Cairn.Pipeline.EpochTagger` immediately ahead of the first buffer of the
  session it names.

  Exists for consumers that buffer metadata cannot reach: the CMAF muxer
  aggregates many samples into one segment buffer, so
  `Cairn.Pipeline.RingBufferSink` learns its epoch from this event instead.
  Events forward through parser and muxer in stream order, ahead of any
  samples those elements are still holding from the *previous* session only
  when the branch is per-session — which it is (see `Cairn.Pipeline.Camera`).
  """

  @derive Membrane.EventProtocol
  defstruct [:epoch, :reason]

  @type t :: %__MODULE__{
          epoch: Cairn.ULID.t(),
          reason: Cairn.StreamEpochs.reason()
        }
end
