defmodule Cairn.Tracker.Stage.TwinMintTest do
  @moduledoc """
  Direct unit tests for `Cairn.Tracker.Stage.TwinMint` at its own boundary —
  the mint-set reading, the kept-versus-reached asymmetry, and the
  score-then-index order. The integrated behavior (through `Tracker.track/3`
  with the flag defaulted on, events and all) stays pinned by
  `tracker_test.exs`'s twin-mint tests and the golden replay suite; the
  off-path is pinned by the `twin_mint_off` golden fixture.
  """

  use ExUnit.Case, async: true

  alias Cairn.Tracker.Batch
  alias Cairn.Tracker.Stage

  # Two boxes of one parked car, overlapping far above the suppression
  # threshold — the observed pre-#68 failure shape.
  @box_a [0.30, 0.30, 0.20, 0.40]
  @box_b [0.32, 0.30, 0.20, 0.40]
  # A third box across the frame: same label, no overlap, a real neighbour.
  @elsewhere [0.70, 0.30, 0.20, 0.40]

  defp object(bbox, score, label \\ "car"), do: %{label: label, score: score, bbox: bbox}

  defp run(indexed, assignments \\ %{}) do
    %Batch{assignment: out} =
      Stage.TwinMint.call(%Batch{indexed: indexed, assignment: assignments}, %{})

    out
  end

  test "the lower-scored twin of a would-be double mint is dropped" do
    out = run([{object(@box_a, 0.9), 0}, {object(@box_b, 0.7), 1}])

    assert out == %{1 => :drop}
  end

  test "score decides the keeper, batch index only breaks ties" do
    assert run([{object(@box_a, 0.7), 0}, {object(@box_b, 0.9), 1}]) == %{0 => :drop}
    assert run([{object(@box_a, 0.9), 0}, {object(@box_b, 0.9), 1}]) == %{1 => :drop}
  end

  test "a spent index is not in the mint set and cannot be a twin" do
    # Box 0 already matched a track: box 1 is the only would-be mint, and a
    # mint set of one has nothing to weigh it against.
    out = run([{object(@box_a, 0.9), 0}, {object(@box_b, 0.7), 1}], %{0 => "track_a"})

    assert out == %{0 => "track_a"}
  end

  test "different labels and distant neighbours both mint" do
    out = [
      {object(@box_a, 0.9), 0},
      {object(@box_b, 0.8, "person"), 1},
      {object(@elsewhere, 0.7), 2}
    ]

    assert run(out) == %{}
  end

  test "a box is weighed against the kept, not the dropped" do
    # Three in a row, 0.06 apart at width 0.2: adjacent pairs overlap at IoU
    # 0.538 (above the 0.4 threshold), the outer pair at 0.25 (below). b
    # drops against a; c overlaps only b, which was dropped — c mints,
    # because what a box is weighed against is the kept set.
    row_a = [0.30, 0.30, 0.20, 0.40]
    row_b = [0.36, 0.30, 0.20, 0.40]
    row_c = [0.42, 0.30, 0.20, 0.40]

    out = run([{object(row_a, 0.9), 0}, {object(row_b, 0.8), 1}, {object(row_c, 0.7), 2}])

    assert out == %{1 => :drop}
  end

  test "constraints pin the stage last at its point" do
    assert Stage.TwinMint.constraints() == %{last_at_point: true}
  end
end
