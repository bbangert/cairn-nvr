defmodule Cairn.TrackPathTest do
  # Every expectation here is a literal worked out by hand from the format
  # documented on `Cairn.TrackPath`. Nothing in this file calls the encoder's
  # own delta/quantize helpers to build an expectation: a test that did would
  # agree with the encoder about a wrong answer, and the on-disk layout is
  # exactly the thing a second implementation (the browser overlay) has to
  # match.
  use ExUnit.Case, async: true

  alias Cairn.TrackPath

  @anchor %{
    first_pts: 1_234,
    timescale: 90_000,
    drained_span_ms: 4_800,
    drain_wall_ms: 1_700_000_000_000,
    event_started_ms: 1_699_999_995_200
  }

  @still [0.4, 0.4, 0.2, 0.2]

  defp header(overrides \\ %{}) do
    Map.merge(%{event_id: "ev-1", camera_id: "driveway"}, overrides)
  end

  # `encode/2` takes the extractor's accumulator, which is newest first. Tests
  # list batches in time order and this is the only place that reverses.
  defp buffered(chronological), do: Enum.reverse(chronological)

  defp roundtrip(header, chronological) do
    binary = TrackPath.encode(header, buffered(chronological))
    assert <<0x1F, 0x8B, _rest::binary>> = binary
    assert {:ok, map} = TrackPath.decode(binary)
    map
  end

  # The running sum a consumer applies to a delta column — stdlib only, so it
  # cannot be wrong in the same direction as the encoder.
  defp undelta(column), do: Enum.scan(column, &(&1 + &2))

  describe "encode/2 and decode/1" do
    test "round-trip carries the header, the anchor and a track's columns" do
      map =
        roundtrip(header(%{truncated: false, anchor: @anchor}), [
          {0, [{"obj-a", "person", [0.1, 0.2, 0.3, 0.4], false}]},
          {500, [{"obj-a", "person", [0.5, 0.25, 0.3, 0.4], false}]}
        ])

      assert map["v"] == 1
      assert map["event_id"] == "ev-1"
      assert map["camera_id"] == "driveway"
      assert map["truncated"] == false

      assert map["anchor"] == %{
               "first_pts" => 1_234,
               "timescale" => 90_000,
               "drained_span_ms" => 4_800,
               "drain_wall_ms" => 1_700_000_000_000,
               "event_started_ms" => 1_699_999_995_200
             }

      assert map["ts"] == [0, 500]

      assert [track] = map["tracks"]

      assert track == %{
               "id" => "obj-a",
               "label" => "person",
               "truncated" => false,
               "ti" => [0, 1],
               "x" => [1_000, 4_000],
               "y" => [2_000, 500],
               "w" => [3_000, 0],
               "h" => [4_000, 0]
             }
    end

    test "a header without :truncated or :anchor writes false and nil" do
      map = roundtrip(header(), [{0, [{"obj-a", "car", [0.0, 0.0, 0.1, 0.1], false}]}])

      assert map["truncated"] == false
      assert map["anchor"] == nil
      assert map["ts"] == [0]

      assert [
               %{
                 "id" => "obj-a",
                 "truncated" => false,
                 "ti" => [0],
                 "x" => [0],
                 "y" => [0],
                 "w" => [1_000],
                 "h" => [1_000]
               }
             ] = map["tracks"]
    end

    test "quantization is lossless for the four-decimal values the wire carries" do
      map =
        roundtrip(header(), [
          {0, [{"o", "person", [0.0001, 0.9999, 0.1234, 0.5678], false}]},
          {1_000, [{"o", "person", [0.9999, 0.0001, 0.5678, 0.1234], false}]},
          {2_000, [{"o", "person", [0.1234, 0.5678, 0.0001, 0.9999], false}]}
        ])

      assert [track] = map["tracks"]

      assert track["x"] == [1, 9_998, -8_765]
      assert undelta(track["x"]) == [1, 9_999, 1_234]

      assert Enum.map(undelta(track["x"]), &(&1 / 10_000)) == [0.0001, 0.9999, 0.1234]
      assert Enum.map(undelta(track["y"]), &(&1 / 10_000)) == [0.9999, 0.0001, 0.5678]
      assert Enum.map(undelta(track["w"]), &(&1 / 10_000)) == [0.1234, 0.5678, 0.0001]
      assert Enum.map(undelta(track["h"]), &(&1 / 10_000)) == [0.5678, 0.1234, 0.9999]
    end

    test "tracks share one timestamp axis and index into it" do
      map =
        roundtrip(header(), [
          {0, [{"a", "person", [0.10, 0.10, 0.20, 0.20], false}]},
          {100,
           [
             {"a", "person", [0.20, 0.10, 0.20, 0.20], false},
             {"b", "car", [0.50, 0.50, 0.10, 0.10], false}
           ]},
          {200, [{"a", "person", [0.30, 0.10, 0.20, 0.20], false}]},
          {300, [{"b", "car", [0.60, 0.50, 0.10, 0.10], false}]}
        ])

      assert map["ts"] == [0, 100, 100, 100]
      assert undelta(map["ts"]) == [0, 100, 200, 300]

      # first-appearance order, not the order the ids happen to sort in
      assert [a, b] = map["tracks"]

      assert a["id"] == "a"
      assert a["label"] == "person"
      assert a["ti"] == [0, 1, 1]
      assert undelta(a["ti"]) == [0, 1, 2]
      assert undelta(a["x"]) == [1_000, 2_000, 3_000]

      assert b["id"] == "b"
      assert b["label"] == "car"
      assert b["ti"] == [1, 2]
      assert undelta(b["ti"]) == [1, 3]
      assert undelta(b["x"]) == [5_000, 6_000]
    end

    test "a track sampled twice at one millisecond keeps the first box only" do
      map =
        roundtrip(header(), [
          {0, [{"a", "person", [0.1, 0.1, 0.1, 0.1], false}]},
          {0, [{"a", "person", [0.9, 0.9, 0.1, 0.1], false}]},
          {100, [{"a", "person", [0.5, 0.5, 0.1, 0.1], false}]}
        ])

      assert map["ts"] == [0, 100]
      assert [track] = map["tracks"]
      assert undelta(track["ti"]) == [0, 1]
      assert undelta(track["x"]) == [1_000, 5_000]
    end

    test "no entries at all encodes a file with no axis and no tracks" do
      map = roundtrip(header(%{anchor: @anchor}), [])

      assert map["event_id"] == "ev-1"
      assert map["ts"] == []
      assert map["tracks"] == []
    end

    test "batches with no boxes encode as no tracks" do
      map = roundtrip(header(), [{0, []}, {100, []}])

      assert map["ts"] == []
      assert map["tracks"] == []
    end
  end

  describe "keyframe selection" do
    test "a stationary run collapses to its first and last sample" do
      map =
        roundtrip(header(), for(t <- [0, 400, 800, 1_200, 1_600, 2_000], do: sample(t, true)))

      # the axis holds only the timestamps of kept samples, so the four
      # suppressed ones leave no slot behind
      assert map["ts"] == [0, 2_000]
      assert undelta(map["ts"]) == [0, 2_000]

      assert [track] = map["tracks"]
      assert track["ti"] == [0, 1]
      assert track["x"] == [4_000, 0]
    end

    test "a stationary flip is kept though the box has not moved" do
      map =
        roundtrip(header(), [
          sample(0, false),
          sample(100, false),
          sample(200, true),
          sample(300, true)
        ])

      # 100 is dropped: same flag, same box, 100 ms since the last kept sample.
      # 200 is the flip; 300 is the last sample.
      assert map["ts"] == [0, 200, 100]
      assert undelta(map["ts"]) == [0, 200, 300]

      assert [track] = map["tracks"]
      assert track["ti"] == [0, 1, 1]
      assert track["x"] == [4_000, 0, 0]
    end

    test "the max-gap rule keeps a sample nothing else would" do
      # Two tracks, same never-moving box, same flag throughout, and both
      # present in the last batch so neither owes its survival to the
      # "last sample" rule. The only thing that differs is how long each waited:
      # "far" goes 2_001 ms without a kept sample and "near" 2_000 ms exactly.
      map =
        roundtrip(header(), [
          {0, [box("far"), box("near")]},
          {1_999, [box("near")]},
          {2_000, [box("near")]},
          {2_001, [box("far")]},
          {2_100, [box("far")]},
          {2_200, [box("far"), box("near")]}
        ])

      assert undelta(map["ts"]) == [0, 2_001, 2_200]
      assert map["ts"] == [0, 2_001, 199]

      assert [far, near] = map["tracks"]

      # far keeps 2_001 on the gap rule alone — nothing moved and no flag
      # flipped — and drops 2_100 (99 ms later); 2_200 is its last sample.
      assert far["id"] == "far"
      assert far["ti"] == [0, 1, 1]
      assert undelta(far["ti"]) == [0, 1, 2]

      # near's 1_999 sits inside the gap and is gone; so is its 2_000, which is
      # the rule's boundary — `more than @max_gap_ms`, not "at least". It keeps
      # only its first and last samples.
      assert near["id"] == "near"
      assert near["ti"] == [0, 2]
      assert undelta(near["ti"]) == [0, 2]
    end

    test "a coordinate move at the epsilon is kept and one below it is not" do
      # 0.4020 - 0.4 = 20 quantized units, exactly @keyframe_delta and so "at
      # least" it; 0.4019 - 0.4 = 19, under it. Both middles are otherwise
      # identical.
      map =
        roundtrip(header(), [
          {0, [{"over", "person", @still, false}, {"under", "person", @still, false}]},
          {100,
           [
             {"over", "person", [0.4020, 0.4, 0.2, 0.2], false},
             {"under", "person", [0.4019, 0.4, 0.2, 0.2], false}
           ]},
          {200, [{"over", "person", @still, false}, {"under", "person", @still, false}]}
        ])

      assert undelta(map["ts"]) == [0, 100, 200]

      assert [over, under] = map["tracks"]

      assert over["id"] == "over"
      assert undelta(over["ti"]) == [0, 1, 2]
      assert undelta(over["x"]) == [4_000, 4_020, 4_000]

      assert under["id"] == "under"
      assert undelta(under["ti"]) == [0, 2]
      assert undelta(under["x"]) == [4_000, 4_000]
    end

    test "a track keeps the label it carried on its first sample" do
      # The tracker re-reads the label off every observation, so a classifier
      # that wavers between two would otherwise rename the path mid-file.
      map =
        roundtrip(header(), [
          {0, [{"a", "person", @still, false}]},
          {100, [{"a", "dog", [0.5, 0.5, 0.2, 0.2], false}]},
          {200, [{"a", "cat", @still, false}]}
        ])

      assert [%{"id" => "a", "label" => "person"}] = map["tracks"]
    end
  end

  describe "truncation" do
    test "the header's flag travels and is independent of the tracks'" do
      map = roundtrip(header(%{truncated: true}), [sample(0, false), sample(100, false)])

      assert map["truncated"] == true
      assert [%{"truncated" => false}] = map["tracks"]
    end

    test "a track over the per-track cap keeps its earliest samples and says so" do
      # x alternates by 0.1 of the frame, so every sample clears the keyframe
      # epsilon and none is suppressed: 6_000 samples in, 5_000 stored.
      chronological =
        for i <- 0..5_999 do
          x = if rem(i, 2) == 0, do: 0.1, else: 0.2
          {i * 10, [{"a", "person", [x, 0.1, 0.1, 0.1], false}]}
        end

      map = roundtrip(header(), chronological)

      assert map["truncated"] == false

      assert [track] = map["tracks"]
      assert track["truncated"] == true
      assert length(track["ti"]) == 5_000
      assert length(track["x"]) == 5_000

      # The earliest survive: the axis has one slot per stored sample and ends
      # at sample 4_999 (t = 49_990), not at sample 5_999 (t = 59_990).
      assert length(map["ts"]) == 5_000
      assert Enum.sum(map["ts"]) == 49_990
      assert hd(map["ts"]) == 0

      assert hd(track["ti"]) == 0
      assert Enum.uniq(tl(track["ti"])) == [1]
    end
  end

  describe "decode/1 failures" do
    test "rejects bytes that were never gzipped" do
      assert TrackPath.decode("this is not a sidecar") == {:error, :not_gzipped}
    end

    test "rejects a file cut short" do
      binary = TrackPath.encode(header(), [{0, [{"a", "person", @still, false}]}])
      cut = binary_part(binary, 0, byte_size(binary) - 4)

      assert TrackPath.decode(cut) == {:error, :not_gzipped}
    end

    test "rejects gzipped bytes that are not a MessagePack map" do
      # 0xC1 is the one byte MessagePack never assigns; 0x2A is the integer 42,
      # well formed but not a map.
      assert TrackPath.decode(:zlib.gzip(<<0xC1>>)) == {:error, :malformed}
      assert TrackPath.decode(:zlib.gzip(<<0x2A>>)) == {:error, :malformed}
    end

    test "rejects a top-level msgpack ext, which unpacks to a struct" do
      # 0xD4 is fixext1: type byte then one data byte. Msgpax hands it back as
      # `%Msgpax.Ext{}`, which `%{}` would happily match — a struct is a map.
      assert TrackPath.decode(:zlib.gzip(<<0xD4, 0x00, 0x00>>)) == {:error, :malformed}
    end
  end

  defp sample(t_ms, stationary), do: {t_ms, [{"a", "person", @still, stationary}]}

  defp box(id), do: {id, "person", @still, false}
end
