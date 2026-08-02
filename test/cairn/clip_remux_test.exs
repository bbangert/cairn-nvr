defmodule Cairn.ClipRemuxTest do
  @moduledoc """
  What `Cairn.ClipRemux` does to a clip's *front*.

  Its own contract — rebasing absolute decode times so the file reports a real
  duration — is covered from the extractor's side in
  `Cairn.EventExtractorTest`. What is here instead is the property the rest of
  the clip pipeline is built on: `-c copy` without `-copyinkf` silently drops
  leading samples it has no keyframe to decode, and records the hole as an
  empty edit. `Cairn.EventExtractor` is what makes sure it is never handed one
  of those; the first two tests pin both sides of that, so a change to either
  the ffmpeg invocation or the ffmpeg version cannot quietly move the line.

  The third is the failure path — an unreadable input, which is also the
  fastest way to get ffmpeg to exit before the caller has finished setting up
  the port around it.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias Cairn.{ClipRemux, MP4Boxes, MP4.Demuxer}

  # Fragments 0/3/6 are keyframe-headed; the GOP spans three fragments. See
  # `mix cairn.gen.fixtures`.
  @fixture "test/support/fixtures/media/testsrc_gop3.fmp4"

  setup do
    dir = Path.join(System.tmp_dir!(), "cairn_remux_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    {_d, events} = Demuxer.push(Demuxer.new("remux"), File.read!(@fixture))
    [{:init, init} | rest] = events
    frags = for {:fragment, f} <- rest, do: f

    %{dir: dir, init: init, frags: frags}
  end

  # Writes exactly what the extractor writes: the init segment, then the given
  # fragments' bytes concatenated.
  defp clip(dir, init, frags, indexes) do
    path = Path.join(dir, "clip_#{System.unique_integer([:positive])}.mp4")
    body = Enum.map_join(indexes, "", &Enum.at(frags, &1).data)
    File.write!(path, init.data <> body)
    path
  end

  defp probe(path, entries) do
    {out, 0} = System.cmd("ffprobe", ~w(-v error -show_entries #{entries} -of csv=p=0) ++ [path])
    out |> String.trim() |> String.split(",") |> Enum.map(&elem(Float.parse(&1), 0))
  end

  test "a clip starting on a keyframe remuxes with no leading empty edit",
       %{dir: dir, init: init, frags: frags} do
    # Fragment 3 is keyframe-headed, so every sample in the clip has something
    # to decode against and the remux has nothing to drop. This is the shape
    # `Cairn.EventExtractor` now guarantees for every clip it writes.
    path = clip(dir, init, frags, [3, 4, 5, 6])

    assert {:ok, size} = ClipRemux.run(path)
    assert size == File.stat!(path).size

    out = File.read!(path)
    refute MP4Boxes.leading_empty_edit?(out)
    # No entry anywhere is an empty one — a trailing or interior `media_time`
    # of −1 would be the same hole, just not at the front.
    refute Enum.any?(MP4Boxes.edit_list(out), &match?({_, -1}, &1))

    [start_time, duration] = probe(path, "format=start_time,duration")
    assert_in_delta start_time, 0.0, 0.001
    # All four fragments, all 1_000 ms of media each, still present.
    assert_in_delta duration, 4.0, 0.05
  end

  test "a clip starting mid-GOP loses its head to an empty edit",
       %{dir: dir, init: init, frags: frags} do
    # Fragments 1 and 2 sit inside the GOP that fragment 0 opened, so `-c copy`
    # cannot carry their samples and drops them. This test is not a wish: it
    # documents the ffmpeg behaviour that makes the keyframe rule in
    # `Cairn.EventExtractor` necessary, and it fails the day ffmpeg starts
    # keeping those samples (at which point the rule can be revisited rather
    # than silently kept for a reason that stopped being true).
    path = clip(dir, init, frags, [1, 2, 3, 4])

    assert {:ok, _size} = ClipRemux.run(path)

    out = File.read!(path)
    assert MP4Boxes.leading_empty_edit?(out)

    # The empty edit's own duration is the dropped span, in the movie timescale
    # rather than ms, so only its sign is asserted here; the seconds are read
    # off the file below.
    assert [{empty_duration, -1} | _] = MP4Boxes.edit_list(out)
    assert empty_duration > 0

    # What a reader sees: content that should have been at t=0 now starts 2 s
    # in — two dropped 1_000 ms fragments, and exactly the skew every
    # media-timeline consumer inherits.
    [start_time, _duration] = probe(path, "format=start_time,duration")
    assert_in_delta start_time, 2.0, 0.05
  end

  test "input ffmpeg cannot read leaves the original and no temp file", %{dir: dir} do
    # The fast-exit path: ffmpeg gives up on the first read. Worth its own test
    # because that is when the spawned shell can be gone before `run_bounded/2`
    # has looked at the port at all.
    path = Path.join(dir, "not_really_an_mp4.mp4")
    File.write!(path, "this is not video")

    log = capture_log(fn -> assert ClipRemux.run(path) == :error end)

    assert log =~ "clip remux failed"
    assert File.read!(path) == "this is not video"
    refute File.exists?(path <> ".remux")
  end
end
