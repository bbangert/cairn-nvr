defmodule Cairn.Tracker.Stage.OcrTest do
  @moduledoc """
  Direct unit tests for `Cairn.Tracker.Stage.Ocr`'s `call/2` at its own
  boundary — the stored-box offer, the threshold, the seeded-reduce dedup,
  the stationary exclusion, and the both-slices reach. The integrated
  behavior (through `Tracker.track/3` with the `ocr` flag, the
  mover-pauses-behind-occluder shape) stays pinned by `tracker_test.exs`
  and the golden replay suite.
  """

  use ExUnit.Case, async: true

  alias Cairn.Tracker.Batch
  alias Cairn.Tracker.Stage

  # The stored (last-observation) box: where the object vanished. The
  # prediction has coasted 0.4 to the right — zero overlap with either box
  # below, which is exactly the regime this stage exists for.
  @stored [0.10, 0.30, 0.10, 0.20]
  @predicted [0.50, 0.30, 0.10, 0.20]
  # Reappears exactly at the stored box: IoU 1.0 against it.
  @reappeared [0.10, 0.30, 0.10, 0.20]
  # Same label, nearby but past the recovery threshold: IoU vs stored is
  # (0.04·0.2)/(2·0.02 − 0.008) = 0.25 — below 0.4.
  @adjacent [0.16, 0.30, 0.10, 0.20]

  defp tracked(overrides) do
    Map.merge(
      %{label: "person", stationary: false, bbox: @stored, last_matched_ms: 0, last_seen_ms: 0},
      Map.new(overrides)
    )
  end

  defp object(bbox), do: %{label: "person", score: 0.9, bbox: bbox}

  defp batch(overrides) do
    struct!(
      Batch,
      Map.merge(
        %{
          context: %{at_ms: 6_000, max_unseen_ms: 3_000},
          candidates: [{"track_a", tracked([]), @predicted}],
          above_floor: [{object(@reappeared), 0}],
          association: :two
        },
        Map.new(overrides)
      )
    )
  end

  test "a box at the stored observation is recovered, into the seeded triple" do
    %Batch{assignment: {assignments, objects, tracks}} = Stage.Ocr.call(batch([]), %{})

    assert assignments == %{0 => "track_a"}
    assert MapSet.member?(objects, 0)
    assert MapSet.member?(tracks, "track_a")
  end

  test "a box below the recovery threshold is not recovered" do
    %Batch{assignment: {assignments, _, _}} =
      Stage.Ocr.call(batch(above_floor: [{object(@adjacent), 0}]), %{})

    assert assignments == %{}
  end

  test "the offer weighs the stored box, never the prediction" do
    # A box overlapping the *prediction* perfectly recovers nothing: the
    # prediction is the association passes' to weigh, and it already had
    # its two chances at this box.
    %Batch{assignment: {assignments, _, _}} =
      Stage.Ocr.call(batch(above_floor: [{object(@predicted), 0}]), %{})

    assert assignments == %{}
  end

  test "the seeded reduce leaves spent objects and tracks alone" do
    taken = {%{0 => "track_b"}, MapSet.new([0]), MapSet.new(["track_b"])}

    %Batch{assignment: assignment} = Stage.Ocr.call(batch(assignment: taken), %{})

    assert assignment == taken
  end

  test "stationary tracks are excluded from recovery" do
    %Batch{assignment: {assignments, _, _}} =
      Stage.Ocr.call(batch(candidates: [{"track_a", tracked(stationary: true), @predicted}]), %{})

    assert assignments == %{}
  end

  test "a different label never recovers" do
    %Batch{assignment: {assignments, _, _}} =
      Stage.Ocr.call(batch(candidates: [{"track_a", tracked(label: "car"), @predicted}]), %{})

    assert assignments == %{}
  end

  test "both floor slices are offered, evidence tier first on equal overlap" do
    # Two boxes at the stored spot, one per tier. Recovery spends the
    # above-floor one: equal overlap resolves by batch index, and the
    # evidence tier indexes first.
    %Batch{assignment: {assignments, _, _}} =
      Stage.Ocr.call(
        batch(
          above_floor: [{object(@reappeared), 0}],
          below_floor: [{object(@reappeared), 1}]
        ),
        %{}
      )

    assert assignments == %{0 => "track_a"}
  end

  test "a below-floor box alone can resume the identity" do
    %Batch{assignment: {assignments, _, _}} =
      Stage.Ocr.call(
        batch(above_floor: [], below_floor: [{object(@reappeared), 1}]),
        %{}
      )

    assert assignments == %{1 => "track_a"}
  end

  test "a box at exactly the threshold is recovered — the admission is >=" do
    # A nested box whose IoU against the stored one is exactly 0.4 in float
    # arithmetic: area 0.008 wholly inside area 0.02, 0.008 / 0.02 == 0.4.
    # A `>=`-to-`>` flip fails here and nowhere else in the suite.
    nested = [0.10, 0.30, 0.05, 0.16]

    %Batch{assignment: {assignments, _, _}} =
      Stage.Ocr.call(batch(above_floor: [{object(nested), 0}]), %{})

    assert assignments == %{0 => "track_a"}
  end

  test "two tracks at one reappearance resolve by id, not map order" do
    # Both stored boxes overlap the reappearance identically, so the pair
    # sort's final `id` component is the only thing keeping the outcome off
    # the candidates list's incidental order — the ULID-map hazard the sort
    # key's comment names.
    candidates = [
      {"track_b", tracked([]), @predicted},
      {"track_a", tracked([]), @predicted}
    ]

    %Batch{assignment: {assignments, _, _}} =
      Stage.Ocr.call(batch(candidates: candidates), %{})

    assert assignments == %{0 => "track_a"}
  end

  test "the recovery threshold is not below suppression's floor" do
    # The cross-constant invariant `Cairn.Tracker` guards at compile time,
    # restated where the number lives: recovery below the suppression floor
    # would resume an identity beside its unsuppressed NMS twin.
    assert Stage.Ocr.recovery_iou() >= 0.4
  end
end
