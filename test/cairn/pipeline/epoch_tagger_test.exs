defmodule Cairn.Pipeline.EpochTaggerTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec

  alias Cairn.Pipeline.{EpochChange, EpochTagger}
  alias Membrane.Buffer
  alias Membrane.RTSPDualStream.Event.StreamClosed
  alias Membrane.Testing

  @format %Membrane.H264{alignment: :au, stream_structure: :annexb}
  @au <<0, 0, 1, 0x65, 0x88>>

  # Returns whatever actions the test hands it, so a session boundary can be
  # scripted exactly — buffers and in-band events interleaved as the RTSP
  # source would emit them.
  defmodule ScriptSource do
    @moduledoc false
    use Membrane.Source

    def_output_pad(:output, accepted_format: _any, flow_control: :push)

    @impl true
    def handle_init(_ctx, _opts), do: {[], %{}}

    @impl true
    def handle_parent_notification(actions, _ctx, state) when is_list(actions),
      do: {actions, state}
  end

  # Reports everything it receives, in arrival order — the only way to assert
  # that an event preceded a buffer rather than merely arrived.
  defmodule RecordSink do
    @moduledoc false
    use Membrane.Sink

    def_input_pad(:input, accepted_format: _any, flow_control: :auto)

    @impl true
    def handle_init(_ctx, _opts), do: {[], %{}}

    @impl true
    def handle_buffer(:input, buffer, _ctx, state), do: {got({:buffer, buffer}), state}

    @impl true
    def handle_event(:input, event, _ctx, state), do: {got({:event, event}), state}

    @impl true
    def handle_stream_format(:input, format, _ctx, state),
      do: {got({:stream_format, format}), state}

    defp got(item), do: [notify_parent: {:got, item}]
  end

  setup do
    camera_id = "tagger_#{System.unique_integer([:positive])}"
    Cairn.StreamEpochs.subscribe()

    pipeline =
      Testing.Pipeline.start_link_supervised!(
        spec: [
          child(:source, ScriptSource)
          |> child(:tagger, %EpochTagger{camera_id: camera_id})
          |> child(:sink, RecordSink)
        ]
      )

    on_exit(fn -> Testing.Pipeline.terminate(pipeline) end)

    %{camera_id: camera_id, pipeline: pipeline}
  end

  defp script(pipeline, actions), do: Testing.Pipeline.notify_child(pipeline, :source, actions)

  defp buffer(pts), do: %Buffer{payload: @au, pts: pts, metadata: %{keyframe?: true}}

  # Consumes the sink's reports in order, so an out-of-order arrival fails the
  # assertion it was meant to satisfy rather than a later one.
  defp next(pipeline) do
    assert_receive {Membrane.Testing.Pipeline, ^pipeline,
                    {:handle_child_notification, {{:got, item}, :sink}}},
                   2_000

    item
  end

  defp refute_event(pipeline) do
    refute_receive {Membrane.Testing.Pipeline, ^pipeline,
                    {:handle_child_notification, {{:got, {:event, _event}}, :sink}}},
                   100
  end

  defp start_session(pipeline, pts \\ 0) do
    script(pipeline, stream_format: {:output, @format}, buffer: {:output, buffer(pts)})

    assert {:stream_format, @format} = next(pipeline)
  end

  test "the first buffer mints, announced ahead of itself and stamped on itself",
       %{pipeline: pipeline} do
    start_session(pipeline)

    assert {:event, %EpochChange{epoch: epoch, reason: :started}} = next(pipeline)
    assert {:buffer, %Buffer{metadata: %{stream_epoch: ^epoch}}} = next(pipeline)
  end

  test "initial_reason names the first mint", %{camera_id: camera_id} do
    pipeline =
      Testing.Pipeline.start_link_supervised!(
        spec: [
          child(:source, ScriptSource)
          |> child(:tagger, %EpochTagger{camera_id: camera_id, initial_reason: :stall_bounce})
          |> child(:sink, RecordSink)
        ]
      )

    start_session(pipeline)

    assert {:event, %EpochChange{reason: :stall_bounce}} = next(pipeline)

    Testing.Pipeline.terminate(pipeline)
  end

  test "the rest of the session is stamped with the same epoch and announces nothing",
       %{pipeline: pipeline} do
    start_session(pipeline)
    assert {:event, %EpochChange{epoch: epoch}} = next(pipeline)
    assert {:buffer, _first} = next(pipeline)

    script(pipeline, buffer: {:output, buffer(1)})
    script(pipeline, buffer: {:output, buffer(2)})

    assert {:buffer, %Buffer{pts: 1, metadata: %{stream_epoch: ^epoch}}} = next(pipeline)
    assert {:buffer, %Buffer{pts: 2, metadata: %{stream_epoch: ^epoch}}} = next(pipeline)
    refute_event(pipeline)
  end

  test "a closed session mints again on the buffer that opens the next one",
       %{pipeline: pipeline} do
    start_session(pipeline)
    assert {:event, %EpochChange{epoch: first}} = next(pipeline)
    assert {:buffer, _first} = next(pipeline)

    # The close alone mints nothing: an epoch minted here would name a session
    # a source that never reconnects would never stream.
    script(pipeline, event: {:output, %StreamClosed{}})
    assert {:event, %StreamClosed{}} = next(pipeline)
    refute_event(pipeline)

    script(pipeline, stream_format: {:output, @format}, buffer: {:output, buffer(0)})

    assert {:stream_format, @format} = next(pipeline)
    assert {:event, %EpochChange{epoch: second, reason: :source_lost}} = next(pipeline)
    assert {:buffer, %Buffer{metadata: %{stream_epoch: ^second}}} = next(pipeline)
    assert second != first
  end

  test "a discontinuity is the same session and mints nothing", %{pipeline: pipeline} do
    start_session(pipeline)
    assert {:event, %EpochChange{epoch: epoch}} = next(pipeline)
    assert {:buffer, _first} = next(pipeline)

    script(pipeline, event: {:output, %Membrane.Event.Discontinuity{}})
    assert {:event, %Membrane.Event.Discontinuity{}} = next(pipeline)

    script(pipeline, buffer: {:output, buffer(1)})
    assert {:buffer, %Buffer{pts: 1, metadata: %{stream_epoch: ^epoch}}} = next(pipeline)
    refute_event(pipeline)
  end

  test "the announced epoch is the one in ETS and on the broadcast",
       %{pipeline: pipeline, camera_id: camera_id} do
    start_session(pipeline)

    assert {:event, %EpochChange{epoch: epoch}} = next(pipeline)

    assert_receive {:stream_epoch, ^camera_id, ^epoch, :started}, 2_000
    assert Cairn.StreamEpochs.current(camera_id) == {:ok, epoch}
  end
end
