defmodule Cairn.Pipeline.RingBufferSinkTest do
  use ExUnit.Case, async: false

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  alias Cairn.{Fragment, RingBuffer}
  alias Cairn.MP4.Demuxer
  alias Cairn.Pipeline.{EpochChange, EpochTagger, RingBufferSink}
  alias Membrane.Buffer
  alias Membrane.Testing

  @h264_fixture "test/support/fixtures/media/testsrc.h264"
  @fmp4_fixture "test/support/fixtures/media/testsrc.fmp4"
  @codec_format ~r/^avc1\.[0-9a-f]{6}$/

  # Enough of a track for the sink: the header is walked for a timescale (this
  # one has no moov, so the 90 kHz fallback applies) and the codecs for the
  # RFC 6381 string.
  @track %Membrane.CMAF.Track{
    content_type: :video,
    header: <<0, 0, 0, 8, "ftyp">>,
    codecs: %{avc1: %{profile: 0x42, compatibility: 0xC0, level: 0x1F}}
  }

  setup do
    camera_id = "sink_#{System.unique_integer([:positive])}"
    epoch = Cairn.ULID.generate()
    # a wide pre-window so the short test stream is never evicted mid-run
    start_supervised!({RingBuffer, camera_id: camera_id, pre_window_seconds: 60})
    Phoenix.PubSub.subscribe(Cairn.PubSub, RingBuffer.topic(camera_id))
    %{camera_id: camera_id, epoch: epoch}
  end

  # The real production seam: the epoch reaches the sink in-band through the
  # muxer, and the sink's own `epoch` is whatever the tagger minted.
  defp run_pipeline(camera_id) do
    spec = [
      child(:src, %Membrane.File.Source{location: @h264_fixture})
      |> child(:parser, %Membrane.H264.Parser{
        output_stream_structure: :avc1,
        generate_best_effort_timestamps: %{framerate: {15, 1}}
      })
      |> child(:tagger, %EpochTagger{camera_id: camera_id})
      |> child(:muxer, %Membrane.MP4.Muxer.CMAF{
        segment_min_duration: Membrane.Time.seconds(2)
      })
      |> child(:sink, %RingBufferSink{camera_id: camera_id})
    ]

    pipeline = Testing.Pipeline.start_link_supervised!(spec: spec)
    assert_end_of_stream(pipeline, :sink, :input, 15_000)
    Testing.Pipeline.terminate(pipeline)

    {:ok, epoch} = Cairn.StreamEpochs.current(camera_id)
    epoch
  end

  defp sink(camera_id) do
    {[], state} = RingBufferSink.handle_init(%{}, struct(RingBufferSink, camera_id: camera_id))
    state
  end

  defp announce(state, epoch) do
    {[], state} = RingBufferSink.handle_event(:input, %EpochChange{epoch: epoch}, %{}, state)
    state
  end

  defp declare(state, track \\ @track) do
    {[], state} = RingBufferSink.handle_stream_format(:input, track, %{}, state)
    state
  end

  test "put_init carries the CMAF header, classic codec string and epoch",
       %{camera_id: camera_id} do
    epoch = run_pipeline(camera_id)

    assert_received {:init_segment, %{camera_id: ^camera_id, codec: codec, epoch: ^epoch} = meta}
    assert codec =~ @codec_format
    assert is_integer(meta.timescale) and meta.timescale > 0

    {:ok, %{init: init, codec: ^codec}} = RingBuffer.fetch_recent(camera_id, 0)
    # a CMAF init segment is ftyp + moov, exactly as the demuxer emits
    assert <<_size::32, "ftyp", _::binary>> = init
  end

  test "fragments feed the ring with monotonic seq, tfdt pts and sane durations",
       %{camera_id: camera_id} do
    run_pipeline(camera_id)

    {:ok, %{fragments: frags}} = RingBuffer.fetch_recent(camera_id, 100)

    assert length(frags) >= 2
    assert Enum.all?(frags, &match?(%Fragment{}, &1))

    # ring re-stamps a fresh 0-based monotonic seq for this first session
    assert Enum.map(frags, & &1.seq) == Enum.to_list(0..(length(frags) - 1))

    pts = Enum.map(frags, & &1.pts)
    assert pts == Enum.sort(pts)
    assert hd(pts) >= 0

    timescale = hd(frags).timescale
    assert timescale > 0
    assert Enum.all?(frags, &(&1.timescale == timescale))
    assert Enum.all?(frags, &(&1.duration_ms > 0))

    # every segment is cut on a keyframe by the muxer, so all are sync-headed
    assert Enum.all?(frags, & &1.keyframe?)

    # data is moof + mdat only (styp/sidx stripped), same framing as the demuxer
    Enum.each(frags, fn f -> assert <<_size::32, "moof", _::binary>> = f.data end)
  end

  test "field shapes match the classic demuxer producer",
       %{camera_id: camera_id} do
    run_pipeline(camera_id)
    {:ok, %{codec: sink_codec, fragments: sink_frags}} = RingBuffer.fetch_recent(camera_id, 100)

    {_d, events} = Demuxer.push(Demuxer.new("cam"), File.read!(@fmp4_fixture))
    [{:init, init} | frag_events] = events
    demuxer_frags = Enum.map(frag_events, fn {:fragment, f} -> f end)

    # both producers speak the same RFC 6381 codec-string shape ...
    assert sink_codec =~ @codec_format
    assert init.codec =~ @codec_format

    # ... and the same Fragment field invariants (not byte equality — the
    # segmenters differ): a sync-headed first fragment, monotonic pts, positive
    # per-fragment durations.
    for frags <- [sink_frags, demuxer_frags] do
      assert hd(frags).keyframe?
      assert Enum.map(frags, & &1.pts) == Enum.sort(Enum.map(frags, & &1.pts))
      assert Enum.all?(frags, &(&1.duration_ms > 0))
    end
  end

  # The muxer emits its output format only after its first input samples, while
  # the event forwards through parser and muxer at once — so neither order is
  # the pipeline's, and both have to init exactly once.
  describe "the epoch/format pair" do
    test "inits once when the event leads", %{camera_id: camera_id, epoch: epoch} do
      camera_id |> sink() |> announce(epoch) |> declare()

      assert_receive {:init_segment, %{camera_id: ^camera_id, epoch: ^epoch}}, 2_000
      refute_receive {:init_segment, _meta}, 100
    end

    test "inits once when the format leads", %{camera_id: camera_id, epoch: epoch} do
      camera_id |> sink() |> declare() |> announce(epoch)

      assert_receive {:init_segment, %{camera_id: ^camera_id, epoch: ^epoch}}, 2_000
      refute_receive {:init_segment, _meta}, 100
    end

    test "a re-emitted format re-inits under the same epoch",
         %{camera_id: camera_id, epoch: epoch} do
      camera_id
      |> sink()
      |> announce(epoch)
      |> declare()
      |> declare(%{@track | codecs: %{avc1: %{profile: 0x4D, compatibility: 0, level: 0x28}}})

      assert_receive {:init_segment, %{epoch: ^epoch, codec: "avc1.42c01f"}}, 2_000
      # the encoder moved, not the session
      assert_receive {:init_segment, %{epoch: ^epoch, codec: "avc1.4d0028"}}, 2_000
    end

    test "a segment arriving before both is dropped and counted, not crashed on",
         %{camera_id: camera_id, epoch: epoch} do
      segment = %Buffer{
        payload: <<0, 0, 0, 8, "moof">>,
        metadata: %{duration: Membrane.Time.seconds(2), independent?: true}
      }

      state = sink(camera_id)
      {[], state} = RingBufferSink.handle_buffer(:input, segment, %{}, state)

      # the epoch alone is not the pair either
      state = announce(state, epoch)
      {[], state} = RingBufferSink.handle_buffer(:input, segment, %{}, state)

      assert {[notify_parent: {:stats, %{dropped: 2, seq: 0}}], _state} =
               RingBufferSink.handle_parent_notification(:stats, %{}, state)

      refute_receive {:fragment, _frag}, 100
    end
  end
end
