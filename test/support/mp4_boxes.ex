defmodule Cairn.MP4Boxes do
  @moduledoc """
  Minimal read-only box walker for assertions about a *finalized* mp4 — the
  plain, remuxed kind `Cairn.ClipRemux` writes, which `Cairn.MP4.Demuxer`
  does not parse (it reads the fragmented stream, and a remuxed clip has no
  `moof` left in it).

  Only what an assertion needs: the edit list, which is where a leading run of
  undecodable samples ends up after `ffmpeg -c copy` drops it.
  """

  @doc """
  Every `elst` entry in the file, flattened across traks, as
  `{segment_duration, media_time}` in the order they appear.

  `[]` means no edit list at all, which is also the "no empty edit" answer.
  """
  @spec edit_list(binary()) :: [{integer(), integer()}]
  def edit_list(mp4) when is_binary(mp4) do
    mp4
    |> collect("elst", [])
    |> Enum.reverse()
    |> Enum.flat_map(&elst_entries/1)
  end

  @doc """
  Whether the file opens with an empty edit — an `elst` entry whose
  `media_time` is −1, the way an mp4 says "present nothing here".

  `ffmpeg -c copy` writes one when the input's leading samples cannot be
  decoded (no keyframe to start on) and it has dropped them: the entry's
  `segment_duration` is exactly the span that went missing, and every reader on
  the media timeline is late by it. A clip that starts on a keyframe has
  nothing to drop and so gets no such entry.
  """
  @spec leading_empty_edit?(binary()) :: boolean()
  def leading_empty_edit?(mp4) when is_binary(mp4) do
    case edit_list(mp4) do
      [{_duration, -1} | _] -> true
      _ -> false
    end
  end

  # -- box walking ------------------------------------------------------------

  # Only containers on the path to `elst` are descended into; `mdat` is skipped
  # wholesale, so this never scans megabytes of sample data looking for a
  # four-byte type that happens to appear in it.
  @containers ~w(moov trak edts mdia minf stbl)

  # Prepend-only, in the order boxes are met, and *never* reversed: a nested
  # descent hands its result back as the accumulator of the sibling walk that
  # follows, so a reverse in any clause here would order the result by the
  # parity of the nesting depth rather than by position in the file. The single
  # reverse belongs to `edit_list/1`, which is what makes its documented
  # document order true for any nesting.
  defp collect(<<size::32, type::binary-size(4), rest::binary>>, wanted, acc)
       when size >= 8 do
    body_size = size - 8

    case rest do
      <<body::binary-size(^body_size), tail::binary>> ->
        acc = if type == wanted, do: [body | acc], else: acc
        acc = if type in @containers, do: collect(body, wanted, acc), else: acc
        collect(tail, wanted, acc)

      _ ->
        acc
    end
  end

  defp collect(_bin, _wanted, acc), do: acc

  # ISO/IEC 14496-12 §8.6.6. Version 1 widens both duration and media_time to
  # 64 bits; `media_rate` is 4 bytes in both and is not read.
  defp elst_entries(<<version::8, _flags::24, count::32, entries::binary>>) do
    entry_size = if version == 1, do: 20, else: 12
    parse_entries(entries, version, count, entry_size, [])
  end

  defp elst_entries(_), do: []

  defp parse_entries(_bin, _version, 0, _size, acc), do: Enum.reverse(acc)

  defp parse_entries(bin, version, count, size, acc) do
    case bin do
      <<entry::binary-size(^size), rest::binary>> ->
        parse_entries(rest, version, count - 1, size, [entry_fields(version, entry) | acc])

      _ ->
        Enum.reverse(acc)
    end
  end

  defp entry_fields(1, <<duration::64, media_time::signed-64, _rate::32>>),
    do: {duration, media_time}

  defp entry_fields(_v0, <<duration::32, media_time::signed-32, _rate::32>>),
    do: {duration, media_time}
end
