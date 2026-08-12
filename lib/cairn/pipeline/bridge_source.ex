defmodule Cairn.Pipeline.BridgeSource do
  @moduledoc """
  Entry element of the membrane pipeline for bridge ingest (`ingest: ffmpeg`):
  pushes MPEG-TS bytes received from the camera's `Cairn.FFmpegPort`
  downstream.

  The ffmpeg OS process and its restart/backoff policy stay in `FFmpegPort`,
  outside the pipeline (D5): a pipeline crash must not take the camera's
  backoff state with it, and a dead camera is a normal long-lived state that
  must not burn supervisor restart intensity. This element outlives every
  ffmpeg the port spawns, so it registers itself under
  `{camera_id, :bridge_source}` in `Cairn.Registry` and the port resolves it
  there — a handshake per session would announce a boundary that no longer
  exists.

  `{:bridge_session_closed, reason}` is that boundary, and it is an in-band
  `Membrane.RTSPDualStream.Event.StreamClosed` rather than an end_of_stream:
  the pipeline outlives sessions now, and only its `Cairn.Pipeline.SessionCut`
  gates decide which branch an EOS ends. `:ts_eos` (and the parent's `:eos`)
  still end the *stream*, for the deliberate stop where the muxer's tail has
  nowhere else to go.
  """

  use Membrane.Source

  alias Membrane.RTSPDualStream.Event.StreamClosed

  def_options(camera_id: [spec: String.t()])

  def_output_pad(:output,
    accepted_format: %Membrane.RemoteStream{type: :bytestream},
    flow_control: :push
  )

  @impl true
  def handle_init(_ctx, opts) do
    {[], %{camera_id: opts.camera_id}}
  end

  @impl true
  def handle_playing(_ctx, state) do
    # Registered only once buffers may be emitted: bytes sent to us before that
    # would be dropped by membrane, and the port would have no way to know.
    {:ok, _pid} = Cairn.Registry.register(state.camera_id, :bridge_source)
    {[stream_format: {:output, %Membrane.RemoteStream{type: :bytestream}}], state}
  end

  @impl true
  def handle_info({:ts_data, data}, ctx, state) when is_binary(data) do
    # Bytes after the stream was ended are a graceful stop overtaking an ffmpeg
    # that has not noticed yet; membrane refuses the buffer with a crash.
    if ctx.pads[:output].end_of_stream? do
      {[], state}
    else
      {[buffer: {:output, %Membrane.Buffer{payload: data}}], state}
    end
  end

  # ffmpeg died (or was bounced): everything it delivered is already in our
  # mailbox ahead of this message, so the event cuts the session exactly where
  # its last byte ended.
  def handle_info({:bridge_session_closed, reason}, _ctx, state) do
    {[event: {:output, %StreamClosed{reason: reason}}], state}
  end

  def handle_info(:ts_eos, ctx, state), do: {eos(ctx), state}

  def handle_info(_msg, _ctx, state), do: {[], state}

  @impl true
  def handle_parent_notification(:eos, ctx, state), do: {eos(ctx), state}

  # An unlinked pad is what a pipeline already tearing down looks like from
  # here, and ending a stream twice is refused: either way there is nothing
  # left to flush.
  defp eos(ctx) do
    case ctx.pads[:output] do
      %{end_of_stream?: false} -> [end_of_stream: :output]
      _gone_or_ended -> []
    end
  end
end
