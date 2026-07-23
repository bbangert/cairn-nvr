defmodule Cairn.RTP.H264Test do
  use ExUnit.Case, async: true

  alias Cairn.RTP.H264

  # NAL header byte: f(1)=0, nri(2)=3, type(5)
  defp nal(type, rest \\ <<>>), do: <<0::1, 3::2, type::5, rest::binary>>

  test "single NAL units" do
    assert H264.keyframe_start?(nal(5))
    assert H264.keyframe_start?(nal(7))
    assert H264.keyframe_start?(nal(8))
    refute H264.keyframe_start?(nal(1))
    refute H264.keyframe_start?(nal(6))
  end

  test "FU-A fragments: only the start fragment of an IDR counts" do
    idr_start = nal(28, <<1::1, 0::1, 0::1, 5::5, "data">>)
    idr_middle = nal(28, <<0::1, 0::1, 0::1, 5::5, "data">>)
    p_start = nal(28, <<1::1, 0::1, 0::1, 1::5, "data">>)

    assert H264.keyframe_start?(idr_start)
    refute H264.keyframe_start?(idr_middle)
    refute H264.keyframe_start?(p_start)
  end

  test "STAP-A aggregates: keyframe if any contained NAL is SPS/PPS/IDR" do
    sps = nal(7, "spsdata")
    sei = nal(6, "sei")
    p = nal(1, "pdata")

    with_sps = nal(24, <<byte_size(sei)::16, sei::binary, byte_size(sps)::16, sps::binary>>)
    without = nal(24, <<byte_size(sei)::16, sei::binary, byte_size(p)::16, p::binary>>)

    assert H264.keyframe_start?(with_sps)
    refute H264.keyframe_start?(without)
  end

  test "garbage is not a keyframe" do
    refute H264.keyframe_start?(<<>>)
    refute H264.keyframe_start?(<<0>>)
  end

  test "nal_type" do
    assert H264.nal_type(nal(28)) == 28
    assert H264.nal_type(<<>>) == nil
  end
end
