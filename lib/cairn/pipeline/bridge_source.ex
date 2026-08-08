defmodule Cairn.Pipeline.BridgeSource do
  @moduledoc """
  Entry element of the membrane pipeline: pushes MPEG-TS bytes received from
  the camera's `Cairn.FFmpegPort` downstream.

  The ffmpeg OS process and its restart/backoff policy stay in `FFmpegPort`,
  outside the pipeline: a pipeline crash must not take the camera's backoff
  state with it, and a dead camera is a normal long-lived state that must not
  burn supervisor restart intensity. This element only announces itself to the
  port owner (`{:bridge_source_ready, pid}`) once it may emit buffers, then
  relays `{:ts_data, binary}` messages as buffers.
  """

  use Membrane.Source

  def_options(
    owner: [
      spec: pid(),
      description: "The camera's FFmpegPort, which streams `{:ts_data, binary}` to us"
    ],
    session: [
      spec: Cairn.ULID.t(),
      description:
        "The stream epoch this pipeline belongs to, echoed in the ready " <>
          "handshake so a stale element outliving a force-kill cannot claim " <>
          "the successor session's byte stream"
    ]
  )

  def_output_pad(:output,
    accepted_format: %Membrane.RemoteStream{type: :bytestream},
    flow_control: :push
  )

  @impl true
  def handle_init(_ctx, opts) do
    {[], %{owner: opts.owner, session: opts.session}}
  end

  @impl true
  def handle_playing(_ctx, state) do
    send(state.owner, {:bridge_source_ready, state.session, self()})
    {[stream_format: {:output, %Membrane.RemoteStream{type: :bytestream}}], state}
  end

  @impl true
  def handle_info({:ts_data, data}, _ctx, state) when is_binary(data) do
    {[buffer: {:output, %Membrane.Buffer{payload: data}}], state}
  end

  # ffmpeg died: everything it delivered is already in our mailbox ahead of
  # this message, so an end_of_stream here lets the CMAF muxer flush its held
  # final segment into the ring instead of dropping up to 2 s of recording on
  # every session end.
  def handle_info(:ts_eos, ctx, state) do
    if ctx.pads.output.end_of_stream? do
      {[], state}
    else
      {[end_of_stream: :output], state}
    end
  end

  def handle_info(_msg, _ctx, state), do: {[], state}
end
