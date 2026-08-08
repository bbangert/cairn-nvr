defmodule Cairn.Pipeline.RTPOutTest do
  use ExUnit.Case, async: false

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  alias Cairn.{RTP, RTPHub}
  alias Membrane.Testing

  @fixture Path.expand("../../support/fixtures/media/testsrc.h264", __DIR__)

  setup do
    camera_id = "rtpout_#{System.unique_integer([:positive])}"
    # port: nil selects the socketless in-process ingest path under test.
    start_supervised!({RTPHub, camera_id: camera_id, port: nil})
    Phoenix.PubSub.subscribe(Cairn.PubSub, RTPHub.topic(camera_id))
    %{camera_id: camera_id}
  end

  defp run(camera_id) do
    h264 = File.read!(@fixture)

    spec = [
      child(:source, %Testing.Source{output: [h264], stream_format: %Membrane.RemoteStream{}})
      |> child(:parser, %Membrane.H264.Parser{
        output_alignment: :au,
        output_stream_structure: :annexb,
        repeat_parameter_sets: true,
        generate_best_effort_timestamps: %{framerate: {15, 1}}
      })
      |> child(:rtp_out, %Cairn.Pipeline.RTPOut{camera_id: camera_id})
    ]

    pipeline = Testing.Pipeline.start_link_supervised!(spec: spec)
    # Anchor on a real end-of-stream rather than inferring the whole stream's
    # end from a quiet gap. RTPOut is a terminal Membrane.Bin (no output pad),
    # so the pipeline never gets handle_element_end_of_stream for it — a bin
    # only relays EOS it can forward downstream, and nothing is downstream. The
    # top-level parser's EOS is the hard signal: the finite Testing.Source is
    # drained and every AU has been forwarded into the bin. The source dumps the
    # whole clip at once (not real-time), so the remaining packets traversing
    # payloader -> sink -> hub arrive in a tight burst, drained below.
    assert_end_of_stream(pipeline, :parser, :input, 10_000)
    drain([])
  end

  # Collect the burst of already-generated packets. The 500 ms gap is not a
  # stream-end heuristic (the parser EOS above already proved that) — it only
  # spans the intra-pipeline process hops for the final few packets.
  defp drain(acc) do
    receive do
      {:rtp, %ExRTP.Packet{} = packet} -> drain([packet | acc])
    after
      500 -> Enum.reverse(acc)
    end
  end

  # Split a flat packet stream into access units on the RTP marker bit (set on
  # each AU's last packet), matching how the payloader delimits AUs.
  defp access_units(packets) do
    packets
    |> Enum.chunk_while(
      [],
      fn p, au ->
        if p.marker, do: {:cont, Enum.reverse([p | au]), []}, else: {:cont, [p | au]}
      end,
      fn au -> if au == [], do: {:cont, []}, else: {:cont, Enum.reverse(au), []} end
    )
  end

  test "packets flow on the rtp topic", %{camera_id: id} do
    assert [%ExRTP.Packet{payload_type: 96} | _] = run(id)
  end

  test "all packets of one AU share a timestamp; timestamps change between AUs", %{camera_id: id} do
    aus = run(id) |> access_units()
    assert length(aus) > 1

    for au <- aus do
      assert au |> Enum.map(& &1.timestamp) |> Enum.uniq() |> length() == 1
    end

    au_ts = Enum.map(aus, fn [p | _] -> p.timestamp end)
    assert au_ts == Enum.uniq(au_ts)
  end

  test "sequence numbers are consecutive mod 2^16 and marker ends each AU", %{camera_id: id} do
    packets = run(id)

    seqs = Enum.map(packets, & &1.sequence_number)
    assert seqs == Enum.map(0..(length(packets) - 1), &rem(&1, 0x1_0000))

    for au <- access_units(packets) do
      {last, rest} = List.pop_at(au, -1)
      assert last.marker
      assert Enum.all?(rest, &(not &1.marker))
    end
  end

  test "keyframe AU's first packet satisfies keyframe_start?", %{camera_id: id} do
    aus = run(id) |> access_units()

    keyframe_aus = Enum.filter(aus, fn [first | _] -> RTP.H264.keyframe_start?(first.payload) end)
    assert length(keyframe_aus) >= 2
  end

  test "gop_snapshot returns oldest-first packets from the last keyframe", %{camera_id: id} do
    packets = run(id)
    snapshot = RTPHub.gop_snapshot(id)

    assert [first | _] = snapshot
    assert RTP.H264.keyframe_start?(first.payload)

    # keyframe reset: the replay buffer holds only the final GOP, not the stream.
    assert length(snapshot) < length(packets)

    seqs = Enum.map(snapshot, & &1.sequence_number)
    assert seqs == Enum.sort(seqs)
  end
end
