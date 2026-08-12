defmodule Membrane.MOTTracker.SparseTrack.Assignment do
  @moduledoc """
  Minimum-cost association with a price on refusing to associate — what
  `lap.lapjv(cost, extend_cost=True, cost_limit=thresh)` computes for the
  reference tracker.

  ## What that call actually solves

  `lapjv` does not drop the pairs above the limit. It builds a square
  `(rows + cols)` matrix — the cost matrix top-left, `thresh / 2` in the two
  off-diagonal blocks, zeroes bottom-right — and solves a *perfect* assignment
  on it, so every row either takes a real column or pays `thresh / 2` for a
  slack one, and every column the same. Summed over a solution, that is
  `Σ cost(i, j) - k · thresh` for `k` real pairs: a pair is worth making
  exactly when it costs less than the limit, and the whole problem is a
  minimum-cost matching under edge weights `cost - thresh`.

  ## Why an independent solver reproduces the reference's answer

  Not by imitating Jonker-Volgenant's internals — by the optimum being unique.
  Two matchings tie only when two disjoint sets of costs sum to the same double,
  which the IoU-and-score arithmetic upstream does not produce except by
  coincidence; where it does, no solver's answer is more correct than another's
  and the parity fixture would show it. So this is an ordinary
  shortest-augmenting-path assignment over the same extended matrix, and the
  argument that it agrees is about the problem, not the code.

  A pair costing **exactly** `thresh` is the one deliberate tie-break: making
  it and refusing it cost the same, and this module refuses it while `lapjv`
  may report it as a match. Nothing upstream guards against that — it is a
  divergence waiting on a cost that lands exactly on a threshold, and the
  parity fixtures are where it would show up.

  ## Scale

  Rows and columns with no cost below the limit are dropped before solving.
  Refusing a pair costs `thresh` — a slack column for the row, a slack row for
  the column — so a pair at or above the limit is never worth more than
  refusing it, and such a row can be settled without solving anything. Dropping
  them is what keeps a crowded frame's `(rows + cols)` square from being solved
  cubically: overlap matrices are nearly all misses, so the surviving problem
  is a handful of rows wide.
  """

  @typedoc "Row/column index pairs, ascending by row."
  @type matches :: [{non_neg_integer(), non_neg_integer()}]

  # Larger than any reachable reduced cost (costs are IoU-derived, so `0..1`,
  # and the potentials stay inside that range), small enough that subtracting
  # deltas from it cannot lose its ordering.
  @unreached 1.0e18

  @doc """
  Associates rows to columns, refusing any pair at or above `thresh`.

  `cost` is a list of rows, all the same length. Returns the matches ascending
  by row index, then the unmatched row indices and the unmatched column
  indices, both ascending — the three values the reference's
  `linear_assignment` returns, in its order.
  """
  @spec solve([[float()]], float()) :: {matches(), [non_neg_integer()], [non_neg_integer()]}
  def solve([], _thresh), do: {[], [], []}

  def solve(cost, thresh) do
    rows = length(cost)
    cols = cost |> hd() |> length()

    live_rows = for {row, i} <- Enum.with_index(cost), Enum.any?(row, &(&1 < thresh)), do: i

    live_cols =
      for j <- 0..(cols - 1)//1,
          Enum.any?(live_rows, fn i -> cost |> Enum.at(i) |> Enum.at(j) |> Kernel.<(thresh) end),
          do: j

    matches = reduced_matches(cost, thresh, live_rows, live_cols)
    matched_rows = MapSet.new(matches, &elem(&1, 0))
    matched_cols = MapSet.new(matches, &elem(&1, 1))

    {matches, for(i <- 0..(rows - 1)//1, i not in matched_rows, do: i),
     for(j <- 0..(cols - 1)//1, j not in matched_cols, do: j)}
  end

  defp reduced_matches(_cost, _thresh, [], _live_cols), do: []

  defp reduced_matches(cost, thresh, live_rows, live_cols) do
    n = length(live_rows)
    m = length(live_cols)

    # `column_row` is the reference's `y`: for each column, the row it took.
    column_row =
      cost
      |> extend(thresh, live_rows, live_cols)
      |> augment_all(n + m)

    # Ascending by row, not by column: the reference reads its solution off the
    # row vector, and the order it reads matches in is the order it applies
    # them — which is the order a track joins the frame's output.
    Enum.sort(
      for j <- 0..(m - 1)//1,
          i = :array.get(j + 1, column_row) - 1,
          i in 0..(n - 1),
          do: {Enum.at(live_rows, i), Enum.at(live_cols, j)}
    )
  end

  # The square `(rows + cols)` matrix `lapjv` solves: the surviving costs
  # top-left, the slack price in the two off-diagonal blocks, and a free
  # bottom-right block where a refused row meets a refused column.
  defp extend(cost, thresh, live_rows, live_cols) do
    n = length(live_rows)
    m = length(live_cols)
    rows = Enum.map(live_rows, &Enum.at(cost, &1))
    slack = thresh / 2

    0..(n + m - 1)
    |> Enum.map(fn i ->
      0..(n + m - 1)
      |> Enum.map(&extended_cost(rows, live_cols, slack, {i, n}, {&1, m}))
      |> List.to_tuple()
    end)
    |> List.to_tuple()
  end

  defp extended_cost(rows, live_cols, _slack, {i, n}, {j, m}) when i < n and j < m do
    rows |> Enum.at(i) |> Enum.at(Enum.at(live_cols, j))
  end

  defp extended_cost(_rows, _live_cols, _slack, {i, n}, {j, m}) when i >= n and j >= m, do: 0.0
  defp extended_cost(_rows, _live_cols, slack, _row, _column), do: slack

  # Shortest augmenting path with dual potentials, one row at a time: the
  # textbook O(n^3) assignment, 1-indexed with column 0 as the virtual source
  # every search starts from.
  defp augment_all(cost, n) do
    zeroes = :array.new(n + 1, default: 0.0)
    unassigned = :array.new(n + 1, default: 0)

    # `u` and `v` carry across rows and are the reason this is optimal rather
    # than merely greedy: they are the dual potentials the augmentations so far
    # have earned, and each search is a shortest path over costs reduced by
    # them. Restarting them per row would find augmenting paths that are not
    # shortest, and an assignment that is not minimal.
    %{p: taken_by} =
      Enum.reduce(1..n, %{u: zeroes, v: zeroes, p: unassigned}, fn row, duals ->
        state = %{
          u: duals.u,
          v: duals.v,
          # Column 0 is the virtual source, holding the row this search is
          # finding a home for.
          p: :array.set(0, row, duals.p),
          way: unassigned,
          minv: :array.new(n + 1, default: @unreached),
          used: :array.new(n + 1, default: false)
        }

        %{u: u, v: v, p: p, way: way, free: free} = search(cost, n, state, 0)

        %{u: u, v: v, p: walk_back(p, way, free)}
      end)

    taken_by
  end

  defp search(cost, n, state, column) do
    state = %{state | used: :array.set(column, true, state.used)}
    row = :array.get(column, state.p)

    {state, delta, next} =
      Enum.reduce(1..n, {state, @unreached, 0}, &relax(cost, row, column, &1, &2))

    state = Enum.reduce(0..n, state, &shift(&1, &2, delta))

    if :array.get(next, state.p) == 0,
      do: Map.put(state, :free, next),
      else: search(cost, n, state, next)
  end

  # One column's reduced cost against the row being explored, and the running
  # minimum over the columns not yet used.
  defp relax(cost, row, column, j, {state, delta, next}) do
    if :array.get(j, state.used) do
      {state, delta, next}
    else
      reduced =
        elem(elem(cost, row - 1), j - 1) - :array.get(row, state.u) - :array.get(j, state.v)

      state =
        if reduced < :array.get(j, state.minv),
          do: %{
            state
            | minv: :array.set(j, reduced, state.minv),
              way: :array.set(j, column, state.way)
          },
          else: state

      candidate = :array.get(j, state.minv)

      if candidate < delta, do: {state, candidate, j}, else: {state, delta, next}
    end
  end

  # The dual update: the explored side pays the step, the unexplored side has
  # it discounted, which keeps every reduced cost non-negative.
  defp shift(j, state, delta) do
    if :array.get(j, state.used) do
      taken = :array.get(j, state.p)

      %{
        state
        | u: :array.set(taken, :array.get(taken, state.u) + delta, state.u),
          v: :array.set(j, :array.get(j, state.v) - delta, state.v)
      }
    else
      %{state | minv: :array.set(j, :array.get(j, state.minv) - delta, state.minv)}
    end
  end

  # The augmenting path, walked back from the free column to the source: each
  # column takes over the row of the column it was reached from.
  defp walk_back(p, way, column) do
    previous = :array.get(column, way)
    p = :array.set(column, :array.get(previous, p), p)

    if previous == 0, do: p, else: walk_back(p, way, previous)
  end
end
