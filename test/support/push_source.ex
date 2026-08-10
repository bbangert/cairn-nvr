defmodule Cairn.PushSource do
  @moduledoc """
  Emits a fixed list of AU buffers from a `flow_control: :push` output pad —
  `Cairn.Pipeline.BridgeSource`'s flow control without its ffmpeg bridge, which
  is what makes the detect branch's shedding testable.
  """

  use Membrane.Source

  def_output_pad(:output, accepted_format: %Membrane.H264{alignment: :au}, flow_control: :push)

  def_options(
    buffers: [spec: [Membrane.Buffer.t()]],
    interval_ms: [
      spec: non_neg_integer(),
      default: 0,
      description: "0 dumps the whole list at once; above that, one buffer per tick"
    ]
  )

  @impl true
  def handle_init(_ctx, opts), do: {[], %{buffers: opts.buffers, interval_ms: opts.interval_ms}}

  @impl true
  def handle_playing(_ctx, %{interval_ms: 0} = state) do
    {[stream_format: {:output, format()}, buffer: {:output, state.buffers}], state}
  end

  def handle_playing(_ctx, state) do
    send(self(), :tick)
    {[stream_format: {:output, format()}], state}
  end

  @impl true
  def handle_info(:tick, _ctx, %{buffers: []} = state), do: {[end_of_stream: :output], state}

  def handle_info(:tick, _ctx, %{buffers: [buffer | rest]} = state) do
    Process.send_after(self(), :tick, state.interval_ms)
    {[buffer: {:output, buffer}], %{state | buffers: rest}}
  end

  defp format, do: %Membrane.H264{alignment: :au, stream_structure: :annexb}
end
