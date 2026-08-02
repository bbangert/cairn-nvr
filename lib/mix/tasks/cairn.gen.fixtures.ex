defmodule Mix.Tasks.Cairn.Gen.Fixtures do
  @shortdoc "Generates committed fmp4 test fixtures with ffmpeg"

  @moduledoc """
  Regenerates the fmp4 fixtures used by demuxer/ring/extractor tests.

      mix cairn.gen.fixtures

  `testsrc.fmp4` and `testsrc_long.fmp4` use the exact `-movflags` the
  production ffmpeg invocation uses. `testsrc_gop3.fmp4` deliberately does
  not — it drops `+frag_keyframe` to reproduce a camera whose GOP outlives its
  fragment duration, which no production flag combination of ours produces but
  plenty of cameras do.

  Requires `ffmpeg` on PATH. Fixtures are committed, so this only needs to
  run when the production muxer flags change.
  """

  use Mix.Task

  @out_dir "test/support/fixtures/media"

  @impl true
  def run(_argv) do
    File.mkdir_p!(@out_dir)
    generate("testsrc.fmp4", duration: 6, rate: 10, gop: 10)
    generate("testsrc_long.fmp4", duration: 30, rate: 10, gop: 10)
    # The mid-GOP fixture. See `@movflags_mid_gop` below for what it varies and
    # why nothing else in the corpus covers it.
    generate("testsrc_gop3.fmp4", duration: 8, rate: 10, gop: 30, mid_gop: true)
    Mix.shell().info("fixtures written to #{@out_dir}")
  end

  # Production's flags. `+frag_keyframe` starts a new fragment at every
  # keyframe, so with `gop <= frag_duration` every fragment begins on one.
  @movflags "+frag_keyframe+empty_moov+default_base_moof"

  # Same muxer minus `+frag_keyframe`, so `-frag_duration` alone decides the
  # boundaries and a GOP three times that long straddles three fragments: only
  # every third one starts on a keyframe. Cameras whose GOP is longer than
  # their fragment duration produce exactly this, and it is the one dimension
  # the other two fixtures hold constant — every fragment in them is
  # keyframe-headed, which makes "drop until a keyframe" a no-op there.
  @movflags_mid_gop "+empty_moov+default_base_moof"

  defp generate(name, opts) do
    out = Path.join(@out_dir, name)

    movflags = if opts[:mid_gop], do: @movflags_mid_gop, else: @movflags

    args =
      [
        "-y",
        "-hide_banner",
        "-loglevel",
        "error",
        "-f",
        "lavfi",
        "-i",
        "testsrc=duration=#{opts[:duration]}:size=320x240:rate=#{opts[:rate]}",
        "-c:v",
        "libx264",
        "-preset",
        "ultrafast",
        "-pix_fmt",
        "yuv420p",
        "-g",
        "#{opts[:gop]}",
        "-movflags",
        movflags,
        "-frag_duration",
        if(opts[:mid_gop], do: "1000000", else: "2000000"),
        "-f",
        "mp4",
        out
      ]

    {output, status} = System.cmd("ffmpeg", args, stderr_to_stdout: true)

    if status != 0 do
      Mix.raise("ffmpeg failed (#{status}): #{output}")
    end
  end
end
