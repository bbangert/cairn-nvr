# Packs a video into the access-unit stream the board harness replays:
# repeated <<pts::signed-64, size::unsigned-32, au::binary-size(size)>>,
# pts in 90 kHz ticks. Wraps `Cairn.Native.Parity.read_clip/2` so the AU
# split and pts provenance are exactly the parity harness's, not a second
# demux path that could disagree with it.
#
#   mix run tools/board-pipeline/pack_clip.exs <video> <out.aus>
#
# (Referenced by run-local.sh and capacity-ladder.sh; used to live in a
# session scratchpad, which is how it got lost once.)

[video, out] =
  case System.argv() do
    [video, out] ->
      [video, out]

    _other ->
      raise ArgumentError, "usage: mix run tools/board-pipeline/pack_clip.exs <video> <out.aus>"
  end

work = Path.join(System.tmp_dir!(), "pack-clip-#{System.unique_integer([:positive])}")
File.mkdir_p!(work)

%{aus: aus, time_base: {num, den}} =
  try do
    Cairn.Native.Parity.read_clip(video, work)
  rescue
    # ffprobe reports "N/A" pts for a raw Annex-B stream — there is no
    # container to carry timestamps. Name the remedy instead of crashing
    # on binary_to_integer("N/A").
    e in ArgumentError ->
      reraise ArgumentError,
              [
                message:
                  "#{Exception.message(e)} — if #{video} is a raw .h264/.h265 " <>
                    "elementary stream it carries no timestamps; wrap it first, e.g. " <>
                    "ffmpeg -f h264 -r 15 -i #{video} -c copy out.mp4 " <>
                    "(-f hevc for .h265)"
              ],
              __STACKTRACE__
  after
    # Both paths: the AUs are already in memory, and the raise path must
    # not leak a scratch tree per attempt.
    File.rm_rf(work)
  end

packed =
  for {au, pts} <- aus, into: <<>> do
    ticks = div(pts * 90_000 * num, den)
    <<ticks::signed-64, byte_size(au)::unsigned-32, au::binary>>
  end

File.write!(out, packed)
IO.puts("packed #{length(aus)} access units -> #{out} (#{byte_size(packed)} bytes)")
