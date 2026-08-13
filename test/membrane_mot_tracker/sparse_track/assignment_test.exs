defmodule Membrane.MOTTracker.SparseTrack.AssignmentTest do
  use ExUnit.Case, async: true

  alias Membrane.MOTTracker.SparseTrack.Assignment

  @thresh 0.75

  test "refuses every pair at or above the limit" do
    cost = [[0.8, 0.9], [0.75, 0.99]]

    assert Assignment.solve(cost, @thresh) == {[], [0, 1], [0, 1]}
  end

  test "returns the matches ascending by row, whatever order they were found in" do
    # The cheap pairs are (1, 0) and (0, 1) — found column-first, they would
    # come back as row 1 then row 0, and the reference applies them in row
    # order (which is the order a track joins the frame's output).
    cost = [[0.9, 0.1], [0.2, 0.9]]

    assert {[{0, 1}, {1, 0}], [], []} = Assignment.solve(cost, @thresh)
  end

  test "an empty problem is not a problem" do
    assert Assignment.solve([], @thresh) == {[], [], []}
    assert Assignment.solve([[], []], @thresh) == {[], [0, 1], []}
  end

  # The claim the whole port rests on is that this finds the *minimum*-cost
  # matching, because the reference's solver finds one too and a minimum that
  # is unique is the same wherever it is computed. Brute force is the only
  # honest check of that: it enumerates every matching there is.
  test "costs no more than the best matching brute force can find" do
    seed = :rand.seed_s(:exsss, {17, 4, 1})

    Enum.reduce(1..500, seed, fn _case, seed ->
      {rows, seed} = :rand.uniform_s(6, seed)
      {cols, seed} = :rand.uniform_s(6, seed)

      {cost, seed} =
        Enum.map_reduce(1..rows, seed, fn _row, seed ->
          Enum.map_reduce(1..cols, seed, fn _column, seed -> :rand.uniform_s(seed) end)
        end)

      {matches, _rows, _cols} = Assignment.solve(cost, @thresh)

      assert total(cost, matches) <= brute_force(cost, rows, cols)

      seed
    end)
  end

  # Every pair costs its cost less the limit, so a pair is worth making exactly
  # when it is cheaper than refusing it — see the module's own account of what
  # the reference's `cost_limit` does.
  defp total(cost, matches) do
    Enum.reduce(matches, 0.0, fn {i, j}, sum ->
      sum + (cost |> Enum.at(i) |> Enum.at(j)) - @thresh
    end)
  end

  defp brute_force(cost, rows, cols) do
    search(cost, 0, rows, cols, MapSet.new(), 0.0)
  end

  defp search(_cost, row, rows, _cols, _taken, sum) when row == rows, do: sum

  defp search(cost, row, rows, cols, taken, sum) do
    skipped = search(cost, row + 1, rows, cols, taken, sum)

    Enum.reduce(0..(cols - 1)//1, skipped, fn column, best ->
      if column in taken do
        best
      else
        value = cost |> Enum.at(row) |> Enum.at(column)

        min(
          best,
          search(cost, row + 1, rows, cols, MapSet.put(taken, column), sum + value - @thresh)
        )
      end
    end)
  end
end
