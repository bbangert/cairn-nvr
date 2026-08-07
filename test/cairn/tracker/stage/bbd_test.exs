defmodule Cairn.Tracker.Stage.BbdTest do
  @moduledoc """
  Direct unit tests for `Cairn.Tracker.Stage.Bbd`'s `call/2` at its own
  boundary — the admission slice, the seeded-reduce dedup, the stationary
  exclusion, and the IoU-refusal precondition. The integrated behavior
  (through `Tracker.track/3` with the `bbd` flag, both evidence tiers,
  events and all) stays pinned by `tracker_test.exs` and the golden replay
  suite.
  """

  use ExUnit.Case, async: true

  alias Cairn.Tracker.Batch
  alias Cairn.Tracker.Stage

  # Predicted box 0.05 × 0.1; the detection sits 0.2 to the right — zero
  # overlap, but at a saturated time term the BBD distance is
  # √((0.2/0.05)² / 0.25) = 8, inside the admit bound (16).
  @predicted [0.10, 0.30, 0.05, 0.10]
  @near [0.30, 0.30, 0.05, 0.10]
  # 0.5 away: √((10)² / 0.25) = 20 — past the bound.
  @far [0.60, 0.30, 0.05, 0.10]
  # Overlapping the prediction well above the IoU threshold: IoU's pair, so
  # never BBD's to weigh.
  @overlapping [0.11, 0.30, 0.05, 0.10]

  defp tracked(overrides) do
    Map.merge(
      %{label: "person", stationary: false, last_matched_ms: 0, last_seen_ms: 0},
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
          above_floor: [{object(@near), 0}],
          association: :one
        },
        Map.new(overrides)
      )
    )
  end

  test "a pair the IoU gate refused is admitted on distance, into the seeded triple" do
    %Batch{assignment: {assignments, objects, tracks}} = Stage.Bbd.call(batch([]), %{})

    assert assignments == %{0 => "track_a"}
    assert MapSet.member?(objects, 0)
    assert MapSet.member?(tracks, "track_a")
  end

  test "a pair past the distance bound is not admitted" do
    %Batch{assignment: {assignments, _, _}} =
      Stage.Bbd.call(batch(above_floor: [{object(@far), 0}]), %{})

    assert assignments == %{}
  end

  test "a pair the IoU gate would have taken is never BBD's to weigh" do
    # The refusal recompute (`Tracker.match_threshold/2`): an overlapping
    # pair belongs to the IoU pass, whatever its distance.
    %Batch{assignment: {assignments, _, _}} =
      Stage.Bbd.call(batch(above_floor: [{object(@overlapping), 0}]), %{})

    assert assignments == %{}
  end

  test "the seeded reduce leaves spent objects and tracks alone" do
    taken = {%{0 => "track_b"}, MapSet.new([0]), MapSet.new(["track_b"])}

    %Batch{assignment: assignment} = Stage.Bbd.call(batch(assignment: taken), %{})

    assert assignment == taken
  end

  test "stationary tracks are excluded from admission" do
    %Batch{assignment: {assignments, _, _}} =
      Stage.Bbd.call(batch(candidates: [{"track_a", tracked(stationary: true), @predicted}]), %{})

    assert assignments == %{}
  end

  test "the association pass picks the admission slice" do
    pair = [{object(@near), 0}]

    # Listed under the wrong tier for the current pass: nothing to admit.
    %Batch{assignment: {stage_two_ignores_above, _, _}} =
      Stage.Bbd.call(batch(association: :two, above_floor: pair, below_floor: []), %{})

    assert stage_two_ignores_above == %{}

    %Batch{assignment: {stage_two_admits_below, _, _}} =
      Stage.Bbd.call(batch(association: :two, above_floor: [], below_floor: pair), %{})

    assert stage_two_admits_below == %{0 => "track_a"}
  end

  describe "appearance fusion (reid: true)" do
    # Signed int8 axis vectors: orthogonal features are distance 1.0 —
    # past the veto; identical are 0.0.
    defp feature(index) do
      for i <- 0..3, into: <<>>, do: <<if(i == index, do: 127, else: 0)::signed-8>>
    end

    defp fused(overrides) do
      batch(
        Keyword.merge([context: %{at_ms: 6_000, max_unseen_ms: 3_000, reid: true}], overrides)
      )
    end

    defp rolling(index), do: Cairn.Tracker.Reid.dequant(feature(index))

    test "a geometry-admitted pair with clashing appearance is vetoed" do
      %Cairn.Tracker.Batch{assignment: {assignments, _, _}} =
        Stage.Bbd.call(
          fused(
            candidates: [{"track_a", tracked(embedding: rolling(0)), @predicted}],
            above_floor: [{Map.put(object(@near), :embedding, feature(1)), 0}]
          ),
          %{}
        )

      assert assignments == %{}
    end

    test "matching appearance is admitted on the same geometry" do
      %Cairn.Tracker.Batch{assignment: {assignments, _, _}} =
        Stage.Bbd.call(
          fused(
            candidates: [{"track_a", tracked(embedding: rolling(0)), @predicted}],
            above_floor: [{Map.put(object(@near), :embedding, feature(0)), 0}]
          ),
          %{}
        )

      assert assignments == %{0 => "track_a"}
    end

    test "a pair missing either side's feature is admitted at its geometry" do
      # Track with state, detection without — and the reverse. No feature is
      # no evidence, in neither direction.
      %Cairn.Tracker.Batch{assignment: {track_only, _, _}} =
        Stage.Bbd.call(
          fused(candidates: [{"track_a", tracked(embedding: rolling(0)), @predicted}]),
          %{}
        )

      assert track_only == %{0 => "track_a"}

      %Cairn.Tracker.Batch{assignment: {det_only, _, _}} =
        Stage.Bbd.call(
          fused(above_floor: [{Map.put(object(@near), :embedding, feature(1)), 0}]),
          %{}
        )

      assert det_only == %{0 => "track_a"}
    end

    test "an intermediate real distance outranks missing evidence" do
      # A partially-correlated feature — <<90, 90, 0, 0>> against axis 0 is
      # cosine distance ~0.29 — beats a track with NO state (neutral 0.5) on
      # identical geometry, without touching the 0.0/1.0 special points the
      # axis fixtures live at, and sits safely under the 0.6 veto.
      correlated = for b <- [90, 90, 0, 0], into: <<>>, do: <<b::signed-8>>

      %Cairn.Tracker.Batch{assignment: {assignments, _, _}} =
        Stage.Bbd.call(
          fused(
            candidates: [
              {"track_blank", tracked([]), @predicted},
              {"track_similar", tracked(embedding: rolling(0)), @predicted}
            ],
            above_floor: [{Map.put(object(@near), :embedding, correlated), 0}]
          ),
          %{}
        )

      assert assignments == %{0 => "track_similar"}
    end

    test "equal geometry resolves by appearance before batch order" do
      # Two tracks with identical predictions — identical geometric distance
      # to the one box — but only track_b's appearance matches it. Flag off,
      # the id tiebreak would hand the box to track_a.
      %Cairn.Tracker.Batch{assignment: {assignments, _, _}} =
        Stage.Bbd.call(
          fused(
            candidates: [
              {"track_a", tracked(embedding: rolling(1)), @predicted},
              {"track_b", tracked(embedding: rolling(0)), @predicted}
            ],
            above_floor: [{Map.put(object(@near), :embedding, feature(0)), 0}]
          ),
          %{}
        )

      assert assignments == %{0 => "track_b"}
    end
  end

  test "constraints declare adjacency and cross-tier pairing" do
    assert Stage.Bbd.constraints() == %{
             adjacent_after: :iou_association,
             paired_across_association: true
           }
  end
end
