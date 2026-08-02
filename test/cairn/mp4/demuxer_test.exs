defmodule Cairn.MP4.DemuxerTest do
  use ExUnit.Case, async: true

  import Bitwise, only: [&&&: 2]

  alias Cairn.Fragment
  alias Cairn.MP4.Demuxer

  @fixture "test/support/fixtures/media/testsrc.fmp4"
  @mid_gop_fixture "test/support/fixtures/media/testsrc_gop3.fmp4"

  defp fixture, do: File.read!(@fixture)

  defp demux(chunks) do
    {_d, events} =
      Enum.reduce(chunks, {Demuxer.new("cam"), []}, fn chunk, {d, acc} ->
        {d, events} = Demuxer.push(d, chunk)
        {d, acc ++ events}
      end)

    events
  end

  defp chunked(binary, size) do
    full = div(byte_size(binary), size)
    chunks = for i <- 0..(full - 1), do: binary_part(binary, i * size, size)
    rem_len = rem(byte_size(binary), size)

    if rem_len == 0 do
      chunks
    else
      chunks ++ [binary_part(binary, full * size, rem_len)]
    end
  end

  test "whole-file push emits init then fragments" do
    events = demux([fixture()])

    assert [{:init, init} | frags] = events
    assert init.codec =~ ~r/^avc1\.[0-9a-f]{6}$/
    assert init.timescale > 0
    assert <<_::binary-size(4), "ftyp", _::binary>> = init.data
    assert length(frags) >= 3
    assert Enum.all?(frags, &match?({:fragment, %Fragment{}}, &1))
  end

  test "fragments have monotonic pts, sane durations, moof+mdat framing" do
    [{:init, _} | frags] = demux([fixture()])
    frags = Enum.map(frags, fn {:fragment, f} -> f end)

    assert Enum.map(frags, & &1.seq) == Enum.to_list(0..(length(frags) - 1))

    pts_list = Enum.map(frags, & &1.pts)
    assert pts_list == Enum.sort(pts_list)

    # 6s of video split into ~2s fragments; every fragment carries duration
    assert Enum.sum(Enum.map(frags, & &1.duration_ms)) in 5_000..7_000

    Enum.each(frags, fn f ->
      assert <<_::binary-size(4), "moof", _::binary>> = f.data
    end)
  end

  describe "keyframe?" do
    test "is true for every fragment of a keyframe-aligned stream" do
      [{:init, _} | frags] = demux([fixture()])
      assert Enum.all?(frags, fn {:fragment, f} -> f.keyframe? end)
    end

    test "follows the GOP when it spans several fragments" do
      [{:init, _} | frags] = demux([File.read!(@mid_gop_fixture)])
      flags = Enum.map(frags, fn {:fragment, f} -> f.keyframe? end)

      # 8 one-second fragments, a keyframe every 3 seconds. The two false
      # entries after each true one are the whole point of this fixture: the
      # other two fixtures are all-true, so nothing else here can tell the two
      # `sample_flags` sources apart.
      assert flags == [true, false, false, true, false, false, true, false]
    end

    test "reads first_sample_flags for the true ones and the tfhd default for the false" do
      # The distinction the parse turns on, asserted at the byte level so a
      # mask that reads the wrong bit cannot pass by agreeing with the fixture
      # by accident. `0x02000000` is sample_depends_on = 2 (an I-frame) with
      # the non-sync bit clear; `0x01010000` is depends_on = 1 with it set.
      [{:init, _} | frags] = demux([File.read!(@mid_gop_fixture)])
      frags = Enum.map(frags, fn {:fragment, f} -> f end)

      keyed = Enum.at(frags, 0)
      assert keyed.keyframe?
      assert {trun_flags, first_sample_flags} = trun_head(keyed.data)
      # 0x4 = first-sample-flags-present
      assert (trun_flags &&& 0x4) != 0
      assert first_sample_flags == 0x02000000

      mid = Enum.at(frags, 1)
      refute mid.keyframe?
      assert {mid_flags, nil} = trun_head(mid.data)
      # no first-sample-flags and no per-sample flags: the answer can only have
      # come from the tfhd default, which is where 0x01010000 lives
      assert (mid_flags &&& 0x4) == 0
      assert (mid_flags &&& 0x400) == 0
      assert tfhd_default_sample_flags(mid.data) == 0x01010000
    end

    # Neither committed fixture sets trun's sample-flags-present bit — ffmpeg
    # writes `first_sample_flags` instead — so this whole branch of the parse,
    # and the offset arithmetic that reaches the flags word inside a sample
    # record, is invisible to every real fmp4 here. These fragments are built
    # by hand for it.
    test "reads the first sample record's own sample_flags when trun carries them" do
      # A tfhd default that says non-sync, overridden per sample: whichever of
      # the two the parse actually reads decides the answer, so they disagree
      # on purpose.
      sync = synthetic_frag(0x01010000, [0x02000000, 0x01010000])
      assert sync.keyframe?

      non_sync = synthetic_frag(0x02000000, [0x01010000, 0x02000000])
      refute non_sync.keyframe?
    end

    test "a trun with no samples starts no clip" do
      # A sync-sample tfhd default, so only the empty sample list can make this
      # false — there is no first sample for a clip to begin on.
      refute synthetic_frag(0x02000000, []).keyframe?
    end

    # `base_data_offset` is the only 8-byte limb in either box, and nothing
    # ffmpeg writes here sets it — so the one skip whose width is not 4 is the
    # one no fixture exercises. Both `base_data_offset` values below are chosen
    # so that reading the default flags from the wrong side of it gives the
    # *opposite* answer, in both directions: a misparse cannot hide behind the
    # `sync_flags?` bias that answers `true` on anything it cannot read.
    test "skips tfhd's 8-byte base_data_offset before reading the default flags" do
      # The trun carries no flags at all, so the tfhd default is the only
      # source. Correct read: 0x01010000, non-sync. Skipping 4 bytes or none
      # lands on a half of `base_data_offset` (0x02020000, sync); skipping 12
      # runs off the end, which the bias also reads as sync.
      non_sync =
        synthetic_frag(0x01010000, [:one_sample],
          trun: :none,
          base_data_offset: 0x0202000002020000
        )

      refute non_sync.keyframe?

      # The mirror: a sync default behind a base_data_offset whose halves are
      # non-sync, so a misparse turns a keyframe fragment into a skipped one.
      sync =
        synthetic_frag(0x02000000, [:one_sample],
          trun: :none,
          base_data_offset: 0x0101000001010000
        )

      assert sync.keyframe?
    end

    test "reads the first sample's flags at offset 0 when duration and size are absent" do
      # trun flags 0x000401: data-offset and sample-flags, *no* duration and no
      # size — `lead` is 0 and `sample_flags` is the whole of each 4-byte
      # record. A lead of 4 or 8 (the widths the other limb orders would give)
      # reads the second record or off the end instead, so the two records
      # disagree and the tfhd default disagrees with both.
      non_sync = synthetic_frag(0x02000000, [0x01010000, 0x02000000], trun: :flags_only)
      refute non_sync.keyframe?

      sync = synthetic_frag(0x01010000, [0x02000000, 0x01010000], trun: :flags_only)
      assert sync.keyframe?
    end
  end

  # Demuxes one hand-built fragment behind the fixture's real init segment,
  # which is where the timescale and the `trex` defaults come from.
  defp synthetic_frag(tfhd_default_flags, sample_flags, opts \\ []) do
    [{:init, init} | _] = demux([fixture()])

    assert [{:init, _}, {:fragment, frag}] =
             demux([init.data, synthetic_fragment(tfhd_default_flags, sample_flags, opts)])

    frag
  end

  # A `moof` + `mdat` with `tfhd` carrying `default_sample_flags` and, by
  # default, `trun` carrying per-sample `sample_flags`.
  #
  # `opts`:
  #
  #   * `:base_data_offset` — an integer to carry in tfhd's 8-byte
  #     `base_data_offset` (flag 0x1). It precedes every other optional tfhd
  #     field, so its presence moves all of them along by 8.
  #   * `:trun` — what each sample record carries. `:full` (the default) is
  #     flags 0x000701: data-offset, sample-duration, sample-size and
  #     sample-flags, so `sample_flags` sits 8 bytes into each 12-byte record.
  #     `:flags_only` is 0x000401, records of one u32. `:none` is 0x000301,
  #     duration and size with no flags anywhere in the trun — under it the
  #     `sample_flags` list is written nowhere and only its length is used, as
  #     the sample count.
  defp synthetic_fragment(tfhd_default_flags, sample_flags, opts) do
    tfhd = tfhd_box(tfhd_default_flags, Keyword.get(opts, :base_data_offset))
    tfdt = mp4_box("tfdt", <<0::8, 0::24, 0::32>>)
    trun = trun_box(sample_flags, Keyword.get(opts, :trun, :full))

    moof =
      mp4_box(
        "moof",
        mp4_box("mfhd", <<0::8, 0::24, 1::32>>) <> mp4_box("traf", tfhd <> tfdt <> trun)
      )

    moof <> mp4_box("mdat", :binary.copy(<<0>>, 16 * length(sample_flags)))
  end

  defp tfhd_box(default_sample_flags, nil) do
    mp4_box("tfhd", <<0::8, 0x000020::24, 1::32, default_sample_flags::32>>)
  end

  defp tfhd_box(default_sample_flags, base_data_offset) do
    mp4_box(
      "tfhd",
      <<0::8, 0x000021::24, 1::32, base_data_offset::64, default_sample_flags::32>>
    )
  end

  defp trun_box(sample_flags, :full) do
    records = for flags <- sample_flags, into: <<>>, do: <<1024::32, 16::32, flags::32>>
    trun_box_with(0x000701, length(sample_flags), records)
  end

  defp trun_box(sample_flags, :flags_only) do
    records = for flags <- sample_flags, into: <<>>, do: <<flags::32>>
    trun_box_with(0x000401, length(sample_flags), records)
  end

  defp trun_box(sample_flags, :none) do
    records = for _ <- sample_flags, into: <<>>, do: <<1024::32, 16::32>>
    trun_box_with(0x000301, length(sample_flags), records)
  end

  defp trun_box_with(flag_word, sample_count, records) do
    mp4_box("trun", <<0::8, flag_word::24, sample_count::32, 0::32>> <> records)
  end

  defp mp4_box(type, body), do: <<byte_size(body) + 8::32, type::binary, body::binary>>

  # `trun` version/flags plus its `first_sample_flags` when present.
  defp trun_head(moof_bytes) do
    <<_version::8, flags::24, _count::32, rest::binary>> = box(moof_bytes, ~w(moof traf trun))
    rest = if (flags &&& 0x1) != 0, do: binary_part(rest, 4, byte_size(rest) - 4), else: rest

    if (flags &&& 0x4) != 0 do
      <<first::32, _::binary>> = rest
      {flags, first}
    else
      {flags, nil}
    end
  end

  defp tfhd_default_sample_flags(moof_bytes) do
    <<_version::8, flags::24, _track_id::32, rest::binary>> = box(moof_bytes, ~w(moof traf tfhd))

    rest =
      Enum.reduce([{0x1, 8}, {0x2, 4}, {0x8, 4}, {0x10, 4}], rest, fn {mask, width}, acc ->
        if (flags &&& mask) != 0, do: binary_part(acc, width, byte_size(acc) - width), else: acc
      end)

    <<default_sample_flags::32, _::binary>> = rest
    default_sample_flags
  end

  # Walks a box path, answering the innermost box's body.
  defp box(bin, [type | rest]) do
    body = find_child(bin, type)
    if rest == [], do: body, else: box(body, rest)
  end

  defp find_child(<<size::32, type::binary-size(4), tail::binary>>, wanted) when size >= 8 do
    body_size = size - 8
    <<body::binary-size(^body_size), after_box::binary>> = tail

    if type == wanted, do: body, else: find_child(after_box, wanted)
  end

  test "any chunking yields identical events" do
    data = fixture()
    reference = demux([data])

    for size <- [17, 977, 4096, 65_536] do
      assert demux(chunked(data, size)) == reference,
             "chunk size #{size} diverged from whole-file parse"
    end
  end

  test "random chunking yields identical events" do
    data = fixture()
    reference = demux([data])

    for seed <- 1..5 do
      :rand.seed(:exsss, {seed, seed, seed})
      chunks = random_chunks(data, [])
      assert demux(chunks) == reference, "random chunking (seed #{seed}) diverged"
    end
  end

  defp random_chunks(<<>>, acc), do: Enum.reverse(acc)

  defp random_chunks(bin, acc) do
    size = min(byte_size(bin), :rand.uniform(20_000))
    <<chunk::binary-size(^size), rest::binary>> = bin
    random_chunks(rest, [chunk | acc])
  end

  test "mdat without moof (mid-stream join) is dropped, stream recovers" do
    data = fixture()
    [{:init, _} | [{:fragment, first} | _]] = demux([data])

    # cut into the middle of the first fragment's mdat: skip init + moof
    moof_size = moof_size(first.data)
    <<_moof::binary-size(^moof_size), mdat::binary>> = first.data

    events = demux([mdat, second_fragment_bytes(data)])
    assert [{:fragment, _}] = events
  end

  defp moof_size(<<size::32, "moof", _::binary>>), do: size

  defp second_fragment_bytes(data) do
    [{:init, _}, {:fragment, _first}, {:fragment, second} | _] = demux([data])
    second.data
  end

  test "desync produces an error event and drops the buffer" do
    {_d, events} = Demuxer.push(Demuxer.new("cam"), <<3::32, "junk", 0, 0, 0, 0>>)
    assert [{:error, {:bad_box_size, 3}}] = events
  end

  test "oversized box produces an error event" do
    {_d, events} = Demuxer.push(Demuxer.new("cam"), <<999_999_999::32, "mdat">>)
    assert [{:error, {:box_too_large, 999_999_999}}] = events
  end
end
