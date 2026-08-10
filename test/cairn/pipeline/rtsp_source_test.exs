defmodule Cairn.Pipeline.RtspSourceTest do
  use ExUnit.Case, async: true

  alias Cairn.Pipeline.RtspSource
  alias Membrane.Buffer

  @epoch "01K0RTSPSRC000000000000000"

  defp element do
    {[], state} = RtspSource.handle_init(%{}, %RtspSource{owner: self(), session: @epoch})
    state
  end

  defp ctx(eos? \\ false), do: %{pads: %{output: %{end_of_stream?: eos?}}}

  test "announces itself with the session epoch and mints the stream format" do
    {actions, _state} = RtspSource.handle_playing(ctx(), element())

    assert_receive {:rtsp_source_ready, @epoch, pid} when pid == self()

    assert [stream_format: {:output, %Membrane.RemoteStream{type: :packetized}}] = actions
  end

  test "relays samples as buffers, pts intact" do
    {actions, _state} =
      RtspSource.handle_info({:rtsp_sample, <<0, 0, 1, 0x65>>, 40_000_000}, ctx(), element())

    assert [buffer: {:output, %Buffer{payload: <<0, 0, 1, 0x65>>, pts: 40_000_000}}] = actions
  end

  test "eos flushes the tail exactly once" do
    {actions, state} = RtspSource.handle_info(:rtsp_eos, ctx(), element())
    assert actions == [end_of_stream: :output]

    # A second session-end signal after the pad already closed is a no-op,
    # not a Membrane error.
    {actions, _state} = RtspSource.handle_info(:rtsp_eos, ctx(true), state)
    assert actions == []
  end

  test "unknown messages are dropped" do
    assert {[], _state} = RtspSource.handle_info({:ts_data, <<1>>}, ctx(), element())
  end
end
