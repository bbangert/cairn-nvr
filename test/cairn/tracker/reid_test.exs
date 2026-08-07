defmodule Cairn.Tracker.ReidTest do
  @moduledoc """
  Unit tests for `Cairn.Tracker.Reid`'s arithmetic. Where the numbers apply
  — flag gating, exclusions, admission — is pinned by the BBD stage tests
  and `tracker_test.exs`.
  """

  use ExUnit.Case, async: true

  alias Cairn.Tracker.Reid

  # Signed int8 quantization of an axis vector: 127 in one slot.
  defp axis(dim, index) do
    for i <- 0..(dim - 1), into: <<>>, do: <<if(i == index, do: 127, else: 0)::signed-8>>
  end

  describe "dequant/1" do
    test "reads signed bytes and normalizes to unit length" do
      # <<127, -127>> — the negative component must come out negative.
      vector = Reid.dequant(<<127::signed-8, -127::signed-8>>)

      assert [a, b] = vector
      assert_in_delta a, 0.7071, 1.0e-3
      assert_in_delta b, -0.7071, 1.0e-3
      assert_in_delta a * a + b * b, 1.0, 1.0e-6
    end

    test "an all-zero vector carries no appearance" do
      assert Reid.dequant(<<0, 0, 0, 0>>) == nil
    end
  end

  describe "roll/2" do
    test "the first feature seeds the state" do
      fresh = Reid.dequant(axis(4, 0))
      assert Reid.roll(nil, fresh) == fresh
    end

    test "the average moves toward the fresh feature and stays unit-norm" do
      rolling = Reid.dequant(axis(4, 0))
      fresh = Reid.dequant(axis(4, 1))

      rolled = Reid.roll(rolling, fresh)

      # Mostly the old identity, a little of the new appearance.
      assert Reid.distance(rolled, rolling) < Reid.distance(rolled, fresh)
      assert_in_delta Enum.reduce(rolled, 0.0, &(&2 + &1 * &1)), 1.0, 1.0e-6
    end
  end

  describe "distance/2" do
    test "identical is 0, orthogonal is 1" do
      a = Reid.dequant(axis(4, 0))
      b = Reid.dequant(axis(4, 1))

      assert_in_delta Reid.distance(a, a), 0.0, 1.0e-6
      assert_in_delta Reid.distance(a, b), 1.0, 1.0e-6
    end

    test "mismatched dimensions carry no comparable appearance" do
      assert Reid.distance(Reid.dequant(axis(4, 0)), Reid.dequant(axis(8, 0))) == nil
    end
  end

  test "the veto sits between plausible same-person distance and orthogonal" do
    # The spike's measured distributions: within 0.33 ± 0.15, between
    # 0.39 ± 0.11. The veto must not sit inside the overlap.
    assert Reid.veto_distance() > 0.5
    assert Reid.veto_distance() < 1.0
  end
end
