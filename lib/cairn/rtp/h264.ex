defmodule Cairn.RTP.H264 do
  @moduledoc """
  Minimal H.264 RTP payload inspection (RFC 6184): detects packets that
  start a keyframe/parameter-set boundary — single NAL units (IDR/SPS/PPS),
  STAP-A aggregates containing one, and FU-A fragments whose start bit
  carries an IDR. Used by `Cairn.RTPHub` to maintain the last-GOP replay
  buffer.
  """

  @idr 5
  @sps 7
  @pps 8
  @stap_a 24
  @fu_a 28

  @keyframe_nals [@idr, @sps, @pps]

  @doc "Does this RTP payload begin a keyframe (IDR/SPS/PPS boundary)?"
  @spec keyframe_start?(binary()) :: boolean()
  def keyframe_start?(<<_f::1, _nri::2, type::5, rest::binary>>) do
    cond do
      type in @keyframe_nals -> true
      type == @stap_a -> stap_a_keyframe?(rest)
      type == @fu_a -> fu_a_keyframe_start?(rest)
      true -> false
    end
  end

  def keyframe_start?(_other), do: false

  @doc "The NAL unit type of this payload (aggregation/fragmentation types included)."
  @spec nal_type(binary()) :: non_neg_integer() | nil
  def nal_type(<<_f::1, _nri::2, type::5, _rest::binary>>), do: type
  def nal_type(_other), do: nil

  defp fu_a_keyframe_start?(<<s::1, _e::1, _r::1, type::5, _rest::binary>>) do
    s == 1 and type in @keyframe_nals
  end

  defp fu_a_keyframe_start?(_), do: false

  defp stap_a_keyframe?(<<size::16, nal::binary-size(size), rest::binary>>) do
    case nal do
      <<_f::1, _nri::2, type::5, _::binary>> when type in @keyframe_nals -> true
      _ -> stap_a_keyframe?(rest)
    end
  end

  defp stap_a_keyframe?(_), do: false
end
