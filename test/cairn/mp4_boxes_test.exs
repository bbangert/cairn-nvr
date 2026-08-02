defmodule Cairn.MP4BoxesTest do
  @moduledoc """
  The box walker behind the edit-list assertions in `Cairn.ClipRemuxTest` and
  `Cairn.EventExtractorTest` — tested directly because those two only ever hand
  it one shape: a single-`elst`, single-video-trak remuxed clip, where any
  ordering at all looks correct.

  `Cairn.MP4Boxes.leading_empty_edit?/1` reads the **head** of the list, so a
  walker whose order depends on how deeply the boxes happen to be nested turns
  the regression test for the leading-empty-edit bug into a silent pass. A
  dual-stream camera is enough to reach that: `Cairn.FFmpegPort` maps `0:v`,
  which maps every video stream, so a clip with two traks is not hypothetical.
  """

  use ExUnit.Case, async: true

  alias Cairn.MP4Boxes

  defp box(type, body), do: <<byte_size(body) + 8::32, type::binary, body::binary>>

  # One version-0 `elst` holding a single entry, tagged by its `media_time` so
  # the two in each file below are told apart by position alone.
  defp elst(media_time, duration \\ 100) do
    box("elst", <<0::8, 0::24, 1::32, duration::32, media_time::signed-32, 65_536::32>>)
  end

  defp trak(children), do: box("trak", children)

  test "entries come out in document order whichever depth they sit at" do
    # Same depth in both traks: what a dual-video-stream clip looks like.
    even =
      box("moov", trak(box("edts", elst(11))) <> trak(box("edts", elst(22))))

    assert MP4Boxes.edit_list(even) == [{100, 11}, {100, 22}]

    # Different depths, and the deeper one second: the parity of the nesting
    # differs between the two elsts, which is exactly what an accumulator
    # reversed once per terminating call gets wrong.
    uneven =
      box(
        "moov",
        trak(box("edts", elst(11))) <>
          trak(box("mdia", box("minf", box("stbl", box("edts", elst(22))))))
      )

    assert MP4Boxes.edit_list(uneven) == [{100, 11}, {100, 22}]

    # And with the deeper one first, so a walker that merely reverses the whole
    # answer cannot pass both.
    swapped =
      box(
        "moov",
        trak(box("mdia", box("minf", box("stbl", box("edts", elst(11)))))) <>
          trak(box("edts", elst(22)))
      )

    assert MP4Boxes.edit_list(swapped) == [{100, 11}, {100, 22}]
  end

  test "leading_empty_edit? reads the first entry in the file, not the deepest" do
    # The empty edit is in the first trak and a real edit in the second; a
    # walker that answers them the other way round says "no empty edit" for a
    # file that opens with one — the exact false pass this guards.
    mp4 =
      box(
        "moov",
        trak(box("edts", elst(-1))) <>
          trak(box("mdia", box("minf", box("stbl", box("edts", elst(0))))))
      )

    assert MP4Boxes.leading_empty_edit?(mp4)

    assert MP4Boxes.edit_list(mp4) == [{100, -1}, {100, 0}]
  end

  test "no edit list at all is the empty answer" do
    assert MP4Boxes.edit_list(box("moov", trak(box("mdia", <<>>)))) == []
    refute MP4Boxes.leading_empty_edit?(box("moov", <<>>))
  end
end
