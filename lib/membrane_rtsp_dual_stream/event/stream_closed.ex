defmodule Membrane.RTSPDualStream.Event.StreamClosed do
  @moduledoc """
  In-band signal that the RTSP session feeding this pad died — teardown,
  socket death, or server-side close — and that the buffers which follow
  (after the source's reconnect) belong to a *new* session: pts restarts
  near zero, decoder references do not carry over, and the first buffer is
  an IDR.

  Distinct from `Membrane.Event.Discontinuity`, which marks mid-session RTP
  loss under a still-live session (pts continues forward).

  `reason` separates a session that simply ended from one this host cut on
  purpose: consumers that mint or record something per session need to say
  which it was. `Membrane.RTSPDualStream.Source` emits `:closed` and nothing
  else — the reasons a host has for cutting are its own.
  """

  @derive Membrane.EventProtocol
  defstruct reason: :closed

  @type t :: %__MODULE__{reason: atom()}
end
