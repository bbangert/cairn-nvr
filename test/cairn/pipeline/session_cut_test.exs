defmodule Cairn.Pipeline.SessionCutTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  require Membrane.Pad

  alias Cairn.Pipeline.{EpochChange, SessionCut}
  alias Membrane.{Buffer, Pad}
  alias Membrane.RTSPDualStream.Event.StreamClosed
  alias Membrane.Testing

  @format %Membrane.H264{alignment: :au, stream_structure: :annexb}
  # SPS, PPS, IDR slice — what a keyframe AU looks like to the NAL walk.
  @keyframe <<0, 0, 1, 0x67, 0x42, 0xC0, 0x1F, 0, 0, 1, 0x68, 0xCE, 0x3C, 0, 0, 1, 0x65, 0x88>>
  # AUD then a non-IDR slice.
  @interframe <<0, 0, 1, 0x09, 0x30, 0, 0, 1, 0x41, 0x9A, 0x02>>

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

  defp start_pipeline(opts \\ []) do
    cut = struct!(SessionCut, Keyword.get(opts, :cut, []))

    spec =
      case Keyword.get(opts, :link, 0) do
        nil ->
          [child(:source, ScriptSource) |> child(:cut, cut)]

        id ->
          [
            child(:source, ScriptSource)
            |> child(:cut, cut)
            |> via_out(Pad.ref(:output, id))
            |> child(sink_name(id), RecordSink)
          ]
      end

    pipeline = Testing.Pipeline.start_link_supervised!(spec: spec)
    on_exit(fn -> Testing.Pipeline.terminate(pipeline) end)
    pipeline
  end

  # A branch of the next session, linked exactly as the pipeline owner would.
  defp link_branch(pipeline, id) do
    Testing.Pipeline.execute_actions(pipeline,
      spec: [
        get_child(:cut)
        |> via_out(Pad.ref(:output, id))
        |> child(sink_name(id), RecordSink)
      ]
    )
  end

  defp sink_name(id), do: :"sink#{id}"

  # The trailing notification is the barrier: without it a `stats` query races
  # the media it is meant to be asking about, since both reach the element from
  # different processes.
  defp script(pipeline, actions) do
    Testing.Pipeline.notify_child(pipeline, :source, actions ++ [notify_parent: :emitted])
    assert_pipeline_notified(pipeline, :source, :emitted, 2_000)
  end

  defp buffer(payload, pts, metadata \\ %{}),
    do: %Buffer{payload: payload, pts: pts, metadata: metadata}

  defp next(pipeline, id) do
    sink = sink_name(id)

    assert_receive {Membrane.Testing.Pipeline, ^pipeline,
                    {:handle_child_notification, {{:got, item}, ^sink}}},
                   2_000

    item
  end

  defp stats(pipeline) do
    Testing.Pipeline.notify_child(pipeline, :cut, :stats)
    assert_pipeline_notified(pipeline, :cut, {:stats, stats}, 2_000)
    stats
  end

  defp open_session(pipeline, id) do
    script(pipeline,
      stream_format: {:output, @format},
      buffer: {:output, buffer(@keyframe, 0, %{keyframe?: true})}
    )

    assert {:stream_format, @format} = next(pipeline, id)
    assert {:buffer, %Buffer{pts: 0}} = next(pipeline, id)
  end

  test "a linked branch sees the stream verbatim, in order" do
    pipeline = start_pipeline()
    open_session(pipeline, 0)

    script(pipeline,
      event: {:output, %EpochChange{epoch: "e", reason: :started}},
      buffer: {:output, buffer(@interframe, 1)}
    )

    assert {:event, %EpochChange{epoch: "e"}} = next(pipeline, 0)
    assert {:buffer, %Buffer{pts: 1}} = next(pipeline, 0)
  end

  @tag :capture_log
  test "a closed session ends its branch's stream, and the next one waits for a pad" do
    pipeline = start_pipeline()
    open_session(pipeline, 0)

    script(pipeline, event: {:output, %StreamClosed{}})

    # EOS is the cut: it is what flushes the muxer's tail into the ring.
    assert_end_of_stream(pipeline, :sink0, :input, 2_000)
    assert_pipeline_notified(pipeline, :cut, {:session_ended, 0}, 2_000)

    # …and the StreamClosed itself never reaches the branch.
    refute_receive {Membrane.Testing.Pipeline, ^pipeline,
                    {:handle_child_notification, {{:got, {:event, %StreamClosed{}}}, :sink0}}},
                   100

    script(pipeline,
      # the stale pre-cut access unit a long-lived TS demuxer can flush behind
      # the close: unusable to a fresh branch, so it dies at the gate
      buffer: {:output, buffer(@interframe, 98)},
      event: {:output, %EpochChange{epoch: "next", reason: :source_lost}},
      buffer: {:output, buffer(@keyframe, 0, %{keyframe?: true})},
      buffer: {:output, buffer(@interframe, 1)}
    )

    assert %{dropped_bytes: dropped, queued_bytes: queued} = stats(pipeline)
    assert dropped == byte_size(@interframe)
    assert queued == byte_size(@keyframe) + byte_size(@interframe)

    link_branch(pipeline, 1)

    # The fresh branch is handed the format it never saw, then the queue as it
    # arrived — the epoch's event ahead of the first buffer it names.
    assert {:stream_format, @format} = next(pipeline, 1)
    assert {:event, %EpochChange{epoch: "next"}} = next(pipeline, 1)
    assert {:buffer, %Buffer{pts: 0}} = next(pipeline, 1)
    assert {:buffer, %Buffer{pts: 1}} = next(pipeline, 1)

    assert stats(pipeline) == %{dropped_bytes: 0, queued_bytes: 0}

    # …and from here the branch is live, nothing queued
    script(pipeline, buffer: {:output, buffer(@interframe, 2)})
    assert {:buffer, %Buffer{pts: 2}} = next(pipeline, 1)
  end

  @tag :capture_log
  test "the keyframe gate reads the NAL when the ingest carries no metadata" do
    pipeline = start_pipeline()
    open_session(pipeline, 0)
    script(pipeline, event: {:output, %StreamClosed{}})
    assert_end_of_stream(pipeline, :sink0, :input, 2_000)

    script(pipeline,
      buffer: {:output, buffer(@interframe, 98)},
      buffer: {:output, buffer(@keyframe, 0)},
      buffer: {:output, buffer(@interframe, 1)}
    )

    assert stats(pipeline).dropped_bytes == byte_size(@interframe)

    link_branch(pipeline, 1)

    assert {:stream_format, @format} = next(pipeline, 1)
    assert {:buffer, %Buffer{pts: 0, payload: @keyframe}} = next(pipeline, 1)
    assert {:buffer, %Buffer{pts: 1}} = next(pipeline, 1)
  end

  @tag :capture_log
  test "the queue is bounded and the surplus counted" do
    pipeline = start_pipeline(cut: [queue_max_bytes: byte_size(@keyframe) + 1], link: nil)

    script(pipeline,
      stream_format: {:output, @format},
      buffer: {:output, buffer(@keyframe, 0, %{keyframe?: true})},
      buffer: {:output, buffer(@interframe, 1)},
      buffer: {:output, buffer(@interframe, 2)}
    )

    assert stats(pipeline) == %{
             dropped_bytes: 2 * byte_size(@interframe),
             queued_bytes: byte_size(@keyframe)
           }
  end

  @tag :capture_log
  test "a session that dies before its branch is linked takes its queue with it" do
    pipeline = start_pipeline()
    open_session(pipeline, 0)

    script(pipeline, event: {:output, %StreamClosed{}})
    assert_end_of_stream(pipeline, :sink0, :input, 2_000)

    script(pipeline,
      event: {:output, %EpochChange{epoch: "orphan", reason: :source_lost}},
      buffer: {:output, buffer(@keyframe, 0, %{keyframe?: true})}
    )

    assert stats(pipeline).queued_bytes == byte_size(@keyframe)

    script(pipeline, event: {:output, %StreamClosed{}})

    assert stats(pipeline) == %{dropped_bytes: byte_size(@keyframe), queued_bytes: 0}

    # …and the gate is re-armed, so the branch that is finally linked starts on
    # the surviving session's IDR and nothing of the orphaned one.
    script(pipeline,
      buffer: {:output, buffer(@interframe, 97)},
      buffer: {:output, buffer(@keyframe, 99, %{keyframe?: true})}
    )

    link_branch(pipeline, 1)

    assert {:stream_format, @format} = next(pipeline, 1)
    assert {:buffer, %Buffer{pts: 99}} = next(pipeline, 1)
  end

  test "a deliberate stop still ends the branch's stream" do
    pipeline = start_pipeline()
    open_session(pipeline, 0)

    script(pipeline, end_of_stream: :output)

    assert_end_of_stream(pipeline, :sink0, :input, 2_000)
  end
end
