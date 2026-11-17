defmodule Cairn.Rockchip.DecodeScale do
  @moduledoc """
  Decode and scale fused (D-G6): AU-aligned H.264 in, decoded by MPP and
  scaled by RGA into a slot of a dma-buf pool, out as `Cairn.Stage.DmaFrame`
  buffers with an empty payload. The slot travels as `metadata.lease`
  alongside the software decoder's keys, and whoever consumes the buffer
  releases it (`Cairn.Rockchip.Download` does); a sampled frame that finds
  every slot held is a drop the NIF counts.

  The lifecycle, sample gate and output slot are `Cairn.Stage.DecoderCore`'s.
  """

  use Membrane.Filter

  alias Cairn.Stage.{DecoderCore, DmaFrame}
  alias Membrane.Buffer

  @behaviour DecoderCore

  def_input_pad(:input,
    accepted_format: %Membrane.H264{alignment: :au},
    flow_control: :manual,
    demand_unit: :buffers
  )

  def_output_pad(:output, accepted_format: %DmaFrame{}, flow_control: :manual)

  def_options(
    camera_id: [spec: String.t()],
    host: [
      spec: module(),
      description:
        "The base's decoder host, called as `open_decoder/4` and `report_decoder_refusal/2`"
    ],
    stream_params: [spec: map(), default: %{}],
    reopen_cooldown_ms: [spec: non_neg_integer(), default: 5_000],
    native: [spec: module(), default: Cairn.Rockchip.Native]
  )

  @impl true
  def handle_init(_ctx, opts) do
    arg = %{
      host: opts.host,
      camera_id: opts.camera_id,
      params: opts.stream_params,
      native: opts.native
    }

    {[],
     DecoderCore.new(
       camera_id: opts.camera_id,
       element: __MODULE__,
       arg: arg,
       cooldown_ms: opts.reopen_cooldown_ms
     )}
  end

  @impl true
  def handle_playing(_ctx, core), do: DecoderCore.playing(core)

  # Swallowed: the output format is the pool's, minted in `output/2`.
  @impl true
  def handle_stream_format(:input, %Membrane.H264{width: w, height: h}, ctx, core) do
    source = if is_integer(w) and is_integer(h), do: {w, h}
    DecoderCore.stream_format(core, source, ctx.resource_guard)
  end

  @impl true
  def handle_buffer(:input, %Buffer{} = buffer, ctx, core) do
    epoch = buffer.metadata[:stream_epoch]
    DecoderCore.buffer(core, buffer.payload, buffer.pts, epoch, ctx.resource_guard)
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, core), do: DecoderCore.demand(core, size)

  @impl true
  def handle_parent_notification(:stats, _ctx, core),
    do: {[notify_parent: {:stats, DecoderCore.stats(core)}], core}

  @impl DecoderCore
  def open_decoder(arg, source),
    do: arg.host.open_decoder(arg.camera_id, arg.params, source, arg.native)

  @impl DecoderCore
  def decoder_refused(arg, message), do: arg.host.report_decoder_refusal(arg.camera_id, message)

  @impl DecoderCore
  def discard(arg, frame), do: arg.native.release(frame.lease)

  @impl DecoderCore
  def output(frame, epoch) do
    format = %DmaFrame{width: frame.width, height: frame.height, format: :RGB, owner: frame.pool}

    metadata =
      frame
      |> Map.take([
        :lease,
        :orig_width,
        :orig_height,
        :scale_x,
        :scale_y,
        :pad_w,
        :pad_h,
        :observed_at_ms,
        :motion
      ])
      |> Map.put(:stream_epoch, epoch)

    {format, %Buffer{pts: frame.pts, payload: <<>>, metadata: metadata}}
  end
end
