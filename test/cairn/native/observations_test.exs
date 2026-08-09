defmodule Cairn.Native.ObservationsTest do
  # No NIF here on purpose: CI's Elixir job has no cargo step, so the term
  # shapes are written out rather than pushed through `Cairn.Native`.
  use ExUnit.Case, async: true

  alias Cairn.Native.Observations
  alias Cairn.Observation
  alias Cairn.ObservationClock
  alias Cairn.PluginProtocol

  @at ~U[2026-07-26 12:34:56.789Z]
  @epoch "01J0000000000000000000000E"

  defp observed_at_ms, do: DateTime.to_unix(@at, :millisecond)

  defp object(attrs \\ %{}) do
    Map.merge(
      %{
        label: "person",
        score: 0.873,
        bbox: [0.1, 0.2, 0.3, 0.4],
        track_id: nil,
        observation_kind: "detected"
      },
      attrs
    )
  end

  defp frame(attrs \\ %{}) do
    Map.merge(
      %{pts: 90_000, observed_at_ms: observed_at_ms(), inferred: true, objects: [object()]},
      attrs
    )
  end

  defp build(frame), do: Observations.from_frame(frame, "cam-1", @epoch)

  describe "from_frame/3" do
    test "is indistinguishable from the same detection off the wire" do
      line =
        Jason.encode!(%{
          "spec" => "cairn.plugin",
          "version" => 1,
          "type" => "frame.objects",
          "camera_id" => "cam-1",
          "stream_epoch" => @epoch,
          "sequence" => 7,
          "frame" => %{
            "pts" => 90_000,
            "time_base" => [1, 90_000],
            "observed_at" => DateTime.to_iso8601(@at)
          },
          "objects" => [%{"label" => "person", "score" => 0.873, "bbox" => [0.1, 0.2, 0.3, 0.4]}]
        })

      {:objects, decoded} = PluginProtocol.decode_line(line, :camera)

      # `sequence` is the only field the two paths cannot agree on: it counts
      # lines in a pipe there is none of here (see the moduledoc).
      assert %{decoded | sequence: nil} == build(frame())
    end

    test "carries the frame's timing onto the struct" do
      observation = build(frame(%{pts: 180_000}))

      assert observation.camera_id == "cam-1"
      assert observation.epoch == @epoch
      assert observation.pts == 180_000
      assert observation.time_base == {1, 90_000}
      assert observation.media_ms == 2000.0
      assert DateTime.compare(observation.observed_at, @at) == :eq
      assert observation.time_quality == :source
      assert observation.protocol == :v1
      assert observation.at_ms == nil
      assert observation.sequence == nil
      assert observation.plugin_instance == nil
      assert observation.ended_tracks == []
      assert observation.invalid_objects == 0
    end

    test "pads observed_at to the precision Ecto dumps at" do
      assert build(frame()).observed_at.microsecond == {789_000, 6}
    end

    test "substitutes the host clock for a timestamp that is not one" do
      # `unix_ms`' answer for a clock it cannot express as a duration since 1970.
      observation = build(frame(%{observed_at_ms: 9_223_372_036_854_775_807}))

      assert observation.time_quality == :arrival
      assert abs(DateTime.diff(observation.observed_at, DateTime.utc_now(), :second)) <= 5
    end

    test "leaves an object's own keys alone" do
      [object] = build(frame()).objects

      assert object == %{
               label: "person",
               score: 0.873,
               bbox: [0.1, 0.2, 0.3, 0.4],
               track_id: nil,
               observation_kind: "detected"
             }
    end

    test "carries an embedding as the bytes it arrived as" do
      embedding = <<0, 127, 255, 1>>
      [object] = build(frame(%{objects: [object(%{embedding: embedding})]})).objects

      assert object.embedding == embedding
    end

    test "an object without an embedding has no embedding key" do
      [object] = build(frame()).objects

      refute Map.has_key?(object, :embedding)
    end

    test "a clamped object still has no embedding key" do
      [object] = build(frame(%{objects: [object(%{bbox: [-0.1, 0.2, 0.3, 0.4]})]})).objects

      refute Map.has_key?(object, :embedding)
    end
  end

  describe "observation_kind" do
    test "a tracked object is kept, and is not evidence" do
      [object] = build(frame(%{objects: [object(%{observation_kind: "tracked"})]})).objects

      assert object.observation_kind == "tracked"
      refute Observation.detected?(object)
    end

    test "a detected object is evidence" do
      [object] = build(frame()).objects

      assert object.observation_kind == "detected"
      assert Observation.detected?(object)
    end
  end

  describe "bbox bounds" do
    test "components are clamped into 0..1" do
      [object] = build(frame(%{objects: [object(%{bbox: [-0.5, 1.5, 2.0, 0.25]})]})).objects

      assert object.bbox == [0.0, 1.0, 1.0, 0.25]
    end

    test "a box already at the bounds is untouched" do
      [object] = build(frame(%{objects: [object(%{bbox: [0.0, 0.0, 1.0, 1.0]})]})).objects

      assert object.bbox == [0.0, 0.0, 1.0, 1.0]
    end

    test "a box with no extent left is dropped and counted" do
      for bbox <- [[0.1, 0.2, 0.0, 0.4], [0.1, 0.2, 0.3, -0.4], [0.1, 0.2], "0,0,1,1"] do
        observation = build(frame(%{objects: [object(%{bbox: bbox})]}))

        assert observation.objects == [], inspect(bbox)
        assert observation.invalid_objects == 1, inspect(bbox)
      end
    end

    test "the valid objects of a frame survive an invalid one, in order" do
      objects = [object(%{label: "car"}), object(%{bbox: [0.0, 0.0, 0.0, 0.0]}), object()]
      observation = build(frame(%{objects: objects}))

      assert Enum.map(observation.objects, & &1.label) == ["car", "person"]
      assert observation.invalid_objects == 1
    end
  end

  describe "the object cap" do
    test "sheds past 64, keeping the strongest, and counts what it shed" do
      objects = for n <- 1..70, do: object(%{label: "o#{n}"})
      observation = build(frame(%{objects: objects}))

      assert length(observation.objects) == 64
      assert Enum.map(observation.objects, & &1.label) == Enum.map(1..64, &"o#{&1}")
      assert observation.invalid_objects == 6
    end

    test "a frame at the cap keeps every object" do
      objects = for n <- 1..64, do: object(%{label: "o#{n}"})
      observation = build(frame(%{objects: objects}))

      assert length(observation.objects) == 64
      assert observation.invalid_objects == 0
    end
  end

  describe "from_frames/5" do
    test "stamps at_ms and hands back the clock to carry forward" do
      {[first], clock} =
        Observations.from_frames(ObservationClock.new(), [frame()], "cam-1", @epoch, 1_000)

      # The first observation of an epoch anchors at the host's clock; the next
      # advances by media time under it.
      assert first.at_ms == 1_000

      {[second], _clock} =
        Observations.from_frames(clock, [frame(%{pts: 135_000})], "cam-1", @epoch, 5_000)

      assert second.media_ms - first.media_ms == 500.0
      assert second.at_ms == 1_500
    end

    test "two frames of one push share now_ms and still take distinct stamps" do
      {[first, second], _clock} =
        Observations.from_frames(
          ObservationClock.new(),
          [frame(), frame(%{pts: 91_000})],
          "cam-1",
          @epoch,
          1_000
        )

      assert first.at_ms == 1_000
      assert second.at_ms == 1_001
    end

    test "a new epoch re-anchors on the host clock" do
      {_first, clock} =
        Observations.from_frames(ObservationClock.new(), [frame()], "cam-1", @epoch, 1_000)

      {[next], _clock} =
        Observations.from_frames(
          clock,
          [frame(%{pts: 0})],
          "cam-1",
          "01J000000000000000000000E2",
          9_000
        )

      assert next.at_ms == 9_000
    end

    test "no frames is no observations and an unchanged clock" do
      clock = ObservationClock.new()

      assert {[], ^clock} = Observations.from_frames(clock, [], "cam-1", @epoch, 1_000)
    end
  end
end
