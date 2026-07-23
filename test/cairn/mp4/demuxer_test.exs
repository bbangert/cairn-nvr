defmodule Cairn.MP4.DemuxerTest do
  use ExUnit.Case, async: true

  alias Cairn.Fragment
  alias Cairn.MP4.Demuxer

  @fixture "test/support/fixtures/media/testsrc.fmp4"

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
