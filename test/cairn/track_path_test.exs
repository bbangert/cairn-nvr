defmodule Cairn.TrackPathTest do
  # Every expectation here is a literal worked out by hand from the format
  # documented on `Cairn.TrackPath`. Nothing in this file calls the encoder's
  # own delta/quantize helpers to build an expectation: a test that did would
  # agree with the encoder about a wrong answer, and the on-disk layout is
  # exactly the thing a second implementation (the browser overlay) has to
  # match.
  use ExUnit.Case, async: true

  alias Cairn.TrackPath

  # The moduledoc's own example, so the format's documentation and the bytes
  # this file pins are the same numbers. The two halves deliberately disagree:
  # the drain half puts the event's t=0 at 0.0 s into the clip and the live half
  # at 0.3 s, which is the 300 ms of in-flight fragment the drain could not see.
  @anchor %{
    first_pts: 1_234,
    timescale: 90_000,
    drained_span_ms: 4_800,
    drain_wall_ms: 1_700_000_000_000,
    live_media_ms: 6_800,
    live_wall_ms: 1_700_000_001_700,
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
               "live_media_ms" => 6_800,
               "live_wall_ms" => 1_700_000_001_700,
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

  describe "anchor_clip_ms/2" do
    # Every expectation below is arithmetic done here, not a call back into the
    # module. @anchor's halves are 300 ms apart by construction, so which one
    # answered is visible in the number rather than inferred from it.
    #
    #   drain: 4_800 + 1_699_999_995_200 − 1_700_000_000_000 =     0
    #   live:  6_800 + 1_699_999_995_200 − 1_700_000_001_700 =   300
    @stored Map.new(@anchor, fn {k, v} -> {to_string(k), v} end)

    test "the live half is preferred when it is there" do
      assert TrackPath.anchor_clip_ms(@stored, 0) == {:ok, 300}
      assert TrackPath.anchor_clip_ms(@stored, 1_500) == {:ok, 1_800}
    end

    test "a missing live half falls through to the drain half" do
      anchor = %{@stored | "live_media_ms" => nil, "live_wall_ms" => nil}

      assert TrackPath.anchor_clip_ms(anchor, 0) == {:ok, 0}
      assert TrackPath.anchor_clip_ms(anchor, 1_500) == {:ok, 1_500}
    end

    # A sidecar written before the live half existed: the two keys are absent
    # from the map rather than nil. Old files are read by the same path.
    test "an anchor that never had the live keys at all falls through" do
      anchor = Map.drop(@stored, ["live_media_ms", "live_wall_ms"])

      assert TrackPath.anchor_clip_ms(anchor, 1_500) == {:ok, 1_500}
    end

    test "half a live half is no live half" do
      assert TrackPath.anchor_clip_ms(%{@stored | "live_wall_ms" => nil}, 0) == {:ok, 0}
      assert TrackPath.anchor_clip_ms(%{@stored | "live_media_ms" => nil}, 0) == {:ok, 0}
    end

    # An ffmpeg respawn restarts pts under a `first_pts` from the old session,
    # so the extractor's subtraction goes negative. The drain half is untouched
    # by that and answers instead.
    test "a negative live media position falls through rather than answering" do
      anchor = %{@stored | "live_media_ms" => -2_000}

      assert TrackPath.anchor_clip_ms(anchor, 0) == {:ok, 0}
    end

    # The line above is only the easy case: −2_000 drags the whole sum under
    # zero, so the "not before the clip" rule would have caught it on its own.
    # This is the case that needs the media position checked in its own right —
    # a wall clock that sits *before* the event's start, which no fragment
    # arrival can produce and only a wrong file can, adds back exactly as much
    # as the position is short and lands on a plausible-looking number.
    test "a negative media position is refused even when the sum comes out plausible" do
      anchor = %{
        @stored
        | "live_media_ms" => -5_000,
          "live_wall_ms" => @stored["event_started_ms"] - 10_000
      }

      # 5_000 is what an unchecked live half would answer here
      assert TrackPath.anchor_clip_ms(anchor, 0) == {:ok, 0}
    end

    test "a half that places the time before the clip is not used" do
      # started 30 s before the wall clock the media was paired with: whatever
      # this file is, it is not this clip's.
      wall = @stored["event_started_ms"] + 30_000
      anchor = %{@stored | "live_wall_ms" => wall, "drain_wall_ms" => wall}

      assert TrackPath.anchor_clip_ms(anchor, 0) == :error

      # ...and the same anchor answers again once the time asked about is far
      # enough into the event to land inside the clip after all.
      assert TrackPath.anchor_clip_ms(anchor, 40_000) == {:ok, 16_800}
    end

    test "no anchor, no usable field, and a non-numeric time are all :error" do
      assert TrackPath.anchor_clip_ms(nil, 0) == :error
      assert TrackPath.anchor_clip_ms(%{}, 0) == :error
      assert TrackPath.anchor_clip_ms(%{"event_started_ms" => 1_699_999_995_200}, 0) == :error
      assert TrackPath.anchor_clip_ms(@stored, nil) == :error
      assert TrackPath.anchor_clip_ms(@stored, "0") == :error
    end

    test "a non-numeric field is refused rather than added" do
      assert TrackPath.anchor_clip_ms(%{@stored | "live_media_ms" => "6800"}, 0) == {:ok, 0}
      assert TrackPath.anchor_clip_ms(%{@stored | "event_started_ms" => nil}, 0) == :error
    end

    # The one test that crosses the writer and the reader: `encode/2` names the
    # fields and this function looks them up, and nothing else in the suite
    # would notice a key renamed in both halves of one file.
    test "reads the keys encode/2 actually writes" do
      map = roundtrip(header(%{anchor: @anchor}), [{0, [{"a", "person", @still, false}]}])

      assert TrackPath.anchor_clip_ms(map["anchor"], 0) == {:ok, 300}
    end
  end

  defp sample(t_ms, stationary), do: {t_ms, [{"a", "person", @still, stationary}]}

  defp box(id), do: {id, "person", @still, false}
end
