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

%{aus: aus, time_base: {num, den}} = Cairn.Native.Parity.read_clip(video, work)
File.rm_rf!(work)

packed =
  for {au, pts} <- aus, into: <<>> do
    ticks = div(pts * 90_000 * num, den)
    <<ticks::signed-64, byte_size(au)::unsigned-32, au::binary>>
  end

File.write!(out, packed)
IO.puts("packed #{length(aus)} access units -> #{out} (#{byte_size(packed)} bytes)")
