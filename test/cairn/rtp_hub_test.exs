defmodule Cairn.RTPHubTest do
  use ExUnit.Case, async: false

  alias Cairn.RTPHub

  defp nal(type, rest \\ <<"x">>), do: <<0::1, 3::2, type::5, rest::binary>>

  defp packet(seq, ts, payload) do
    ExRTP.Packet.new(payload, payload_type: 96, sequence_number: seq, timestamp: ts, ssrc: 42)
  end

  setup do
    camera_id = "hub_#{System.unique_integer([:positive])}"
    start_supervised!({RTPHub, camera_id: camera_id})

    push = fn seq, ts, payload -> RTPHub.push_packet(camera_id, packet(seq, ts, payload)) end

    %{camera_id: camera_id, push: push}
  end

  test "broadcasts pushed packets on the rtp topic", %{camera_id: id, push: push} do
    Phoenix.PubSub.subscribe(Cairn.PubSub, RTPHub.topic(id))

    push.(1, 1000, nal(1))

    assert_receive {:rtp, %ExRTP.Packet{sequence_number: 1, timestamp: 1000}}, 2_000
  end

  test "gop buffer resets on keyframe boundaries", %{camera_id: id, push: push} do
    Phoenix.PubSub.subscribe(Cairn.PubSub, RTPHub.topic(id))

    # GOP 1: keyframe + two P packets
    push.(1, 1000, nal(7))
    push.(2, 1000, nal(5))
    push.(3, 2000, nal(1))
    assert_receive {:rtp, %{sequence_number: 3}}, 2_000

    assert [1, 2, 3] = RTPHub.gop_snapshot(id) |> Enum.map(& &1.sequence_number)

    # GOP 2 starts: buffer resets to the new keyframe
    push.(4, 3000, nal(7))
    push.(5, 4000, nal(1))
    assert_receive {:rtp, %{sequence_number: 5}}, 2_000

    assert [4, 5] = RTPHub.gop_snapshot(id) |> Enum.map(& &1.sequence_number)
  end

  test "FU-A continuation of the same keyframe does not reset", %{camera_id: id, push: push} do
    Phoenix.PubSub.subscribe(Cairn.PubSub, RTPHub.topic(id))

    # fragmented IDR: same timestamp, start then continuation
    push.(10, 5000, nal(28, <<1::1, 0::1, 0::1, 5::5, "a">>))
    push.(11, 5000, nal(28, <<1::1, 0::1, 0::1, 5::5, "b">>))
    push.(12, 5000, nal(28, <<0::1, 1::1, 0::1, 5::5, "c">>))
    assert_receive {:rtp, %{sequence_number: 12}}, 2_000

    # same-timestamp keyframe fragments must not clear each other
    assert [10, 11, 12] = RTPHub.gop_snapshot(id) |> Enum.map(& &1.sequence_number)
  end
end
