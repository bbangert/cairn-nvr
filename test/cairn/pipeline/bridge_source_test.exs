defmodule Cairn.Pipeline.BridgeSourceTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  alias Cairn.Pipeline.BridgeSource
  alias Membrane.Buffer
  alias Membrane.RTSPDualStream.Event.StreamClosed
  alias Membrane.Testing

  defp start_source do
    id = "bs_#{System.unique_integer([:positive])}"

    pipeline =
      Testing.Pipeline.start_link_supervised!(
        spec: child(:source, %BridgeSource{camera_id: id}) |> child(:sink, Testing.Sink)
      )

    on_exit(fn -> Testing.Pipeline.terminate(pipeline) end)
    {pipeline, id, await_registered(id)}
  end

  # Registration is what `Cairn.FFmpegPort` resolves the element by, and it is
  # deliberately no earlier than handle_playing: bytes sent before that would
  # be dropped by membrane with the port none the wiser.
  defp await_registered(id, attempts \\ 200) do
    case Cairn.Registry.whereis(id, :bridge_source) do
      pid when is_pid(pid) ->
        pid

      nil when attempts > 0 ->
        Process.sleep(10)
        await_registered(id, attempts - 1)

      nil ->
        flunk("bridge source for #{id} never registered")
    end
  end

  test "relays the port's TS bytes as buffers" do
    {pipeline, _id, source} = start_source()

    send(source, {:ts_data, <<1, 2, 3>>})
    assert_sink_buffer(pipeline, :sink, %Buffer{payload: <<1, 2, 3>>})
  end

  test "a closed session is an in-band event; the element outlives it" do
    {pipeline, _id, source} = start_source()

    send(source, {:ts_data, <<1>>})
    assert_sink_buffer(pipeline, :sink, %Buffer{payload: <<1>>})

    # Not an end_of_stream: the pipeline outlives sessions now, and only the
    # SessionCut gates decide which branch an EOS ends.
    send(source, {:bridge_session_closed, :stall_bounce})
    assert_sink_event(pipeline, :sink, %StreamClosed{reason: :stall_bounce})

    send(source, {:ts_data, <<2>>})
    assert_sink_buffer(pipeline, :sink, %Buffer{payload: <<2>>})
  end

  test ":ts_eos ends the stream and later bytes are dropped, not crashed on" do
    {pipeline, _id, source} = start_source()

    send(source, {:ts_data, <<1>>})
    assert_sink_buffer(pipeline, :sink, %Buffer{payload: <<1>>})

    send(source, :ts_eos)
    assert_end_of_stream(pipeline, :sink)

    # ffmpeg has not noticed the stop yet; membrane refuses a buffer — and an
    # event — past EOS with a crash, so the element has to drop all three of
    # the port's late message kinds.
    send(source, {:ts_data, <<2>>})
    send(source, {:bridge_session_closed, :closed})
    send(source, :ts_eos)
    refute_sink_buffer(pipeline, :sink, %Buffer{}, 200)
    refute_sink_event(pipeline, :sink, %StreamClosed{}, 0)
    assert Process.alive?(source)
  end

  test "the parent's :eos flushes exactly as the port's does" do
    {pipeline, _id, _source} = start_source()

    Testing.Pipeline.notify_child(pipeline, :source, :eos)
    assert_end_of_stream(pipeline, :sink)
  end
end
