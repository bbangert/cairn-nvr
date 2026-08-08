defmodule Cairn.Pipeline.RingBufferSink do
  @moduledoc """
  Terminates a `Membrane.MP4.Muxer.CMAF` output track into a camera's
  `Cairn.RingBuffer`, shaping each segment into the same `Cairn.Fragment` the
  classic `Cairn.MP4.Demuxer` path produces.

  The bytes differ (a different segmenter), but the fields a consumer keys on do
  not: `data` is `moof`+`mdat` only (styp/sidx stripped, as the demuxer drops
  them), `pts` is the track-timescale `tfdt` time, `codec` is the demuxer's
  RFC 6381 shape, and `keyframe?` means "first sample is a sync sample".
  Matching those is what lets the Membrane pipeline stand in for the
  ffmpeg-stdout one with no viewer- or extractor-visible change.
  """

  use Membrane.Sink

  alias Cairn.{Fragment, RingBuffer}

  def_input_pad :input, accepted_format: Membrane.CMAF.Track, flow_control: :auto

  def_options camera_id: [spec: String.t()],
              epoch: [spec: Cairn.ULID.t()]

  @impl true
  def handle_init(_ctx, opts) do
    {[], %{camera_id: opts.camera_id, epoch: opts.epoch, timescale: nil, seq: 0}}
  end

  @impl true
  def handle_stream_format(:input, %Membrane.CMAF.Track{} = format, _ctx, state) do
    # nil means our box walker failed on the muxer's init, not that the init
    # is unusable; falling back to Fragment's default keeps timing math
    # wrong-but-bounded instead of crashing the ring — whose death restarts
    # the whole camera tree (:rest_for_one), a far worse outcome.
    timescale = video_timescale(format.header) || 90_000

    # A re-emitted stream format (mid-session encoder change) is treated as a
    # fresh init: the ring drops its buffered fragments and restarts pts at ~0,
    # so the per-session seq counter restarts with it. The ring re-stamps its
    # own monotonic seq regardless, so this counter only needs to be 0-based.
    RingBuffer.put_init(
      state.camera_id,
      format.header,
      codec_string(format.codecs),
      timescale,
      state.epoch
    )

    {[], %{state | timescale: timescale, seq: 0}}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    frag = %Fragment{
      camera_id: state.camera_id,
      seq: state.seq,
      pts: base_media_decode_time(buffer.payload),
      # `metadata.duration` is the segment's sample span as `Membrane.Time` (ns).
      duration_ms: Membrane.Time.as_milliseconds(buffer.metadata.duration, :round),
      timescale: state.timescale,
      # The muxer only ends a segment on a keyframe, so `independent?` is its own
      # reading of "first sample is a sync sample" — exactly Fragment.keyframe?.
      # (Always true for segments; only chunks, which this pipeline never emits,
      # can be non-independent.)
      keyframe?: buffer.metadata.independent?,
      data: moof_and_mdat(buffer.payload)
    }

    RingBuffer.put_fragment(state.camera_id, frag)

    {[], %{state | seq: state.seq + 1}}
  end

  # RFC 6381 codec string in the exact shape `Cairn.MP4.Demuxer` emits
  # ("avc1.PPCCLL"), so a viewer keying off it sees one format across both
  # producers. The muxer keys the map by the input's stream structure (`:avc1`
  # or `:avc3`); the RFC 6381 sample-entry brand is "avc1" for both.
  defp codec_string(codecs) do
    case Enum.find(codecs, fn {tag, _info} -> tag in [:avc1, :avc3] end) do
      {_tag, %{profile: profile, compatibility: compat, level: level}} ->
        "avc1." <> Base.encode16(<<profile, compat, level>>, case: :lower)

      _ ->
        nil
    end
  end

  # A CMAF video segment is `styp sidx moof mdat`; a classic fragment is
  # `moof mdat` (the demuxer drops styp/sidx). Slicing from the moof reproduces
  # that byte-for-byte, and reading pts from the moof's own tfdt matches the
  # demuxer's tfdt-derived pts exactly — the output buffer itself carries no pts.
  defp moof_and_mdat(<<size::32, "moof", _::binary>> = segment) when size >= 8, do: segment

  defp moof_and_mdat(<<size::32, _type::binary-size(4), _::binary>> = segment) when size >= 8 do
    case segment do
      <<_::binary-size(^size), rest::binary>> -> moof_and_mdat(rest)
      # truncated prefix box: recording the bytes as-is beats crashing the
      # session over framing (only styp/sidx have been walked past here)
      _ -> segment
    end
  end

  defp moof_and_mdat(segment), do: segment

  defp base_media_decode_time(segment) do
    with moof when is_binary(moof) <- find_box(segment, "moof"),
         traf when is_binary(traf) <- find_box(moof, "traf"),
         tfdt when is_binary(tfdt) <- find_box(traf, "tfdt") do
      tfdt_time(tfdt)
    else
      _ -> 0
    end
  end

  defp tfdt_time(<<0::8, _flags::24, time::32, _::binary>>), do: time
  defp tfdt_time(<<1::8, _flags::24, time::64, _::binary>>), do: time
  defp tfdt_time(_), do: 0

  # Track (media) timescale from the init segment's first `trak`. The pipeline
  # this sink terminates carries a single video track, so the first trak is it;
  # the tfdt read above is in these units.
  defp video_timescale(header) do
    with moov when is_binary(moov) <- find_box(header, "moov"),
         trak when is_binary(trak) <- find_box(moov, "trak"),
         mdia when is_binary(mdia) <- find_box(trak, "mdia"),
         mdhd when is_binary(mdhd) <- find_box(mdia, "mdhd") do
      mdhd_timescale(mdhd)
    else
      _ -> nil
    end
  end

  defp mdhd_timescale(<<0::8, _flags::24, _c::32, _m::32, timescale::32, _::binary>>),
    do: timescale

  defp mdhd_timescale(<<1::8, _flags::24, _c::64, _m::64, timescale::32, _::binary>>),
    do: timescale

  defp mdhd_timescale(_), do: nil

  # Body of the first top-level box of `type` in `bin`, else nil. 32-bit sizes
  # only: every box walked here (moov/trak/mdia/mdhd, moof/traf/tfdt) is small
  # and the muxer serializes them with 32-bit box sizes.
  defp find_box(<<size::32, type::binary-size(4), rest::binary>>, want) when size >= 8 do
    body_size = size - 8

    case rest do
      <<body::binary-size(^body_size), tail::binary>> ->
        if type == want, do: body, else: find_box(tail, want)

      _ ->
        nil
    end
  end

  defp find_box(_bin, _want), do: nil
end
