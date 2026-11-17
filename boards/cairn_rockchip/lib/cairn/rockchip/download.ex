defmodule Cairn.Rockchip.Download do
  @moduledoc """
  The adapter from `Cairn.Rockchip.DecodeScale`'s dma-buf frames to the RGB
  ones every other element takes: each buffer's lease is read out as tightly
  packed RGB24 rows of the content rectangle and released, downloaded or not.

  Both pads are `:manual` and demand passes through one-for-one, as the
  base's motion gate does, so the decoder's newest-wins slot still sees the
  model's pace. The hop's input queue prefetches a lease, so with no motion
  gate the frame inference takes is one sample period older than the
  software chain's — the age that chain's frames have behind a gate. A failed
  download is counted and dropped. A rebuilt pool (a new `owner`) re-sends
  the same RGB format downstream, which is harmless: the gate only re-plans
  its thumbnail.
  """

  use Membrane.Filter

  alias Cairn.Stage.DmaFrame
  alias Membrane.Buffer

  def_input_pad(:input,
    accepted_format: %DmaFrame{},
    flow_control: :manual,
    demand_unit: :buffers
  )

  def_output_pad(:output,
    accepted_format: %Membrane.RawVideo{pixel_format: :RGB},
    flow_control: :manual
  )

  def_options(native: [spec: module(), default: Cairn.Rockchip.Native])

  @impl true
  def handle_init(_ctx, opts), do: {[], %{native: opts.native, frames: 0, failed: 0}}

  @impl true
  def handle_stream_format(:input, %DmaFrame{} = format, _ctx, state) do
    rgb = %Membrane.RawVideo{
      width: format.width,
      height: format.height,
      pixel_format: :RGB,
      framerate: nil,
      aligned: true
    }

    {[stream_format: {:output, rgb}], state}
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state), do: {[demand: {:input, size}], state}

  # A lease still queued on the input pad when the element stops is released
  # by its resource's destructor. One clause: a buffer with no lease breaks
  # the `DmaFrame` contract, which is a crash, not input to drop.
  @impl true
  def handle_buffer(:input, %Buffer{metadata: %{lease: lease} = metadata} = buffer, _ctx, state) do
    downloaded = state.native.download(lease)
    :ok = state.native.release(lease)

    case downloaded do
      {:ok, rgb} ->
        out = %{buffer | payload: rgb, metadata: Map.delete(metadata, :lease)}
        {[buffer: {:output, out}], %{state | frames: state.frames + 1}}

      # The output demand this buffer was to meet is still open.
      {:error, _reason} ->
        {[demand: {:input, &(&1 + 1)}], %{state | failed: state.failed + 1}}
    end
  end

  @impl true
  def handle_parent_notification(:stats, _ctx, state),
    do: {[notify_parent: {:stats, %{frames: state.frames, failed: state.failed}}], state}
end
