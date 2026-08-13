defmodule Membrane.MOTTracker.SparseTrack.Kalman do
  @moduledoc """
  SparseTrack's own motion filter: an 8-dimensional constant-velocity Kalman
  filter over a box's centre, **width and height** — `[cx, cy, w, h, vcx, vcy,
  vw, vh]`.

  ## Why this is not `Membrane.MOTTracker.Kalman`

  The tree's other filter is DeepSORT's `[cx, cy, a, h, ...]`: it tracks the
  aspect ratio `w/h` instead of the width, and scales every noise term by the
  height alone (with fixed constants for the two aspect terms). SparseTrack
  inherited BoT-SORT's `xywh` filter instead, whose noise is scaled **per axis**
  — the `w` terms by the width, the `h` terms by the height. The two are
  different estimators, not two spellings of one: they disagree on every
  predicted box after the first update, so a track's overlap with a detection
  differs, so the association differs, so the identities differ. Reusing the
  `xyah` filter here would not be a rounding difference against the reference —
  it would be a different tracker.

  ## Units

  Pixels, and only pixels. The reference's overlap arithmetic carries the
  `cython_bbox` `+1`-pixel convention and its pseudo-depth is `2000 - y2`, an
  absolute pixel constant; both are meaningless against frame-normalized boxes.
  Nothing here enforces that — it is the caller's contract, stated in
  `Membrane.MOTTracker.SparseTrack`.

  ## Arithmetic

  Written to reproduce the reference's *value*, not merely its algebra: the
  operation order of every scalar expression follows
  `tools/mot-bench/vendor/sparsetrack/kalman_filter.py`, and the linear solve is
  a Cholesky factorization with forward/back substitution rather than an
  explicit inverse, because that is what `scipy.linalg.cho_factor` /
  `cho_solve` do. Each inner sum is accumulated first and subtracted once (the
  shape LAPACK's `dsyrk`/`dtrsm` give it), not subtracted term by term.
  """

  @std_weight_position 1 / 20
  @std_weight_velocity 1 / 160

  @typedoc "The 4-vector `[cx, cy, w, h]` a box is observed as."
  @type measurement :: [float()]

  @typedoc "A dense matrix as rows of floats."
  @type matrix :: [[float()]]

  @typedoc "The 8-vector mean and its 8x8 covariance."
  @type t :: {[float()], matrix()}

  @doc """
  A filter seeded from one measurement, velocities at zero.

  The initial covariance is the reference's: twice the position weight for the
  four observed quantities and ten times the velocity weight for the four
  unobserved ones, each against the axis it belongs to.
  """
  @spec initiate(measurement()) :: t()
  def initiate([x, y, w, h]) do
    stds = [
      2 * @std_weight_position * w,
      2 * @std_weight_position * h,
      2 * @std_weight_position * w,
      2 * @std_weight_position * h,
      10 * @std_weight_velocity * w,
      10 * @std_weight_velocity * h,
      10 * @std_weight_velocity * w,
      10 * @std_weight_velocity * h
    ]

    {[x, y, w, h, 0.0, 0.0, 0.0, 0.0], diagonal(squared(stds))}
  end

  @doc """
  One constant-velocity step.

  The motion matrix is identity plus the velocity coupling, so `F·P·Fᵀ` reduces
  to two additions per entry — which is why this is bit-identical to the
  reference's `multi_predict` however its BLAS chose to sum: only two terms of
  each dot product are non-zero, and a sum of two doubles rounds the same way
  everywhere.
  """
  @spec predict(t()) :: t()
  def predict({mean, covariance}) do
    [_cx, _cy, w, h | _velocities] = mean

    motion_cov =
      diagonal(
        squared([
          @std_weight_position * w,
          @std_weight_position * h,
          @std_weight_position * w,
          @std_weight_position * h,
          @std_weight_velocity * w,
          @std_weight_velocity * h,
          @std_weight_velocity * w,
          @std_weight_velocity * h
        ])
      )

    covariance =
      covariance
      |> motion_rows()
      |> Enum.map(&motion_columns/1)
      |> mat_add(motion_cov)

    {motion_columns(mean), covariance}
  end

  @doc """
  The measurement update against an observed `[cx, cy, w, h]`.

  Posterior covariance as `P - K·S·Kᵀ`, the reference's form — not the
  algebraically equal `(I - K·H)·P`, which rounds differently.
  """
  @spec update(t(), measurement()) :: t()
  def update({mean, covariance}, measurement) do
    {projected_mean, projected_cov} = project(mean, covariance)

    # `P·Hᵀ` is the first four columns of P, and `S·Kᵀ = (P·Hᵀ)ᵀ` is what the
    # reference's `cho_solve` is handed — so the solve is over the transpose and
    # the gain comes back transposed too.
    gain = transpose(cho_solve(projected_cov, transpose(Enum.map(covariance, &Enum.take(&1, 4)))))
    innovation = vec_sub(measurement, projected_mean)

    posterior =
      mat_sub(covariance, gain |> mat_mul(projected_cov) |> mat_mul(transpose(gain)))

    {vec_add(mean, mat_vec(gain, innovation)), posterior}
  end

  @doc "The filter's `[x, y, w, h]` box: the mean's centre, cornered."
  @spec tlwh(t()) :: [float()]
  def tlwh({[cx, cy, w, h | _velocities], _covariance}) do
    [cx - w / 2, cy - h / 2, w, h]
  end

  @doc """
  Zeroes the two size velocities.

  The reference does this to every pool member that is not in the tracked state
  before predicting it: a track nothing has confirmed for a while may go on
  drifting, but it may not go on growing.
  """
  @spec freeze_size_velocity(t()) :: t()
  def freeze_size_velocity({[cx, cy, w, h, vcx, vcy, _vw, _vh], covariance}) do
    {[cx, cy, w, h, vcx, vcy, 0, 0], covariance}
  end

  # -- projection and the linear solve ----------------------------------------

  @spec project([float()], matrix()) :: {[float()], matrix()}
  defp project(mean, covariance) do
    [_cx, _cy, w, h | _velocities] = mean

    innovation_cov =
      diagonal(
        squared([
          @std_weight_position * w,
          @std_weight_position * h,
          @std_weight_position * w,
          @std_weight_position * h
        ])
      )

    projected_cov =
      covariance
      |> Enum.take(4)
      |> Enum.map(&Enum.take(&1, 4))
      |> mat_add(innovation_cov)

    {Enum.take(mean, 4), projected_cov}
  end

  # Solves `S·X = B` for a positive-definite `S`, as LAPACK's `dpotrf`/`dpotrs`
  # pair does: factor once, then a forward and a back substitution per column.
  @spec cho_solve(matrix(), matrix()) :: matrix()
  defp cho_solve(s, b) do
    lower = cholesky(s)
    columns = transpose(b)

    columns
    |> Enum.map(fn column -> column |> forward_substitute(lower) |> back_substitute(lower) end)
    |> transpose()
  end

  # Lower-triangular `L` with `L·Lᵀ = a`. Each entry subtracts one accumulated
  # sum rather than one term at a time, which is the order `dsyrk` gives it.
  @spec cholesky(matrix()) :: matrix()
  defp cholesky(a) do
    n = length(a)

    Enum.reduce(0..(n - 1), [], fn i, rows ->
      row = Enum.reduce(0..i, [], &cholesky_entry(Enum.at(a, i), rows, &1, &2, i))

      rows ++ [row]
    end)
  end

  # One entry of `L`, appended to the row being built. `entries` is
  # `L[i][0..j-1]`; the row it pairs with is `L[j]`, which for the diagonal
  # entry is that same row under construction.
  @spec cholesky_entry([float()], matrix(), non_neg_integer(), [float()], non_neg_integer()) ::
          [float()]
  defp cholesky_entry(a_i, rows, j, entries, i) do
    paired = if j == i, do: entries, else: Enum.at(rows, j)
    residual = Enum.at(a_i, j) - dot(entries, Enum.take(paired, j))

    value =
      if i == j,
        do: :math.sqrt(residual),
        else: residual / (rows |> Enum.at(j) |> Enum.at(j))

    entries ++ [value]
  end

  @spec forward_substitute([float()], matrix()) :: [float()]
  defp forward_substitute(b, lower) do
    b
    |> Enum.with_index()
    |> Enum.reduce([], fn {value, i}, solved ->
      row = Enum.at(lower, i)
      solved ++ [(value - dot(solved, Enum.take(row, i))) / Enum.at(row, i)]
    end)
  end

  @spec back_substitute([float()], matrix()) :: [float()]
  defp back_substitute(y, lower) do
    n = length(y)

    Enum.reduce((n - 1)..0//-1, List.duplicate(0.0, n), fn i, solved ->
      # Column `i` of `L` below the diagonal is row `i` of `Lᵀ` to the right of
      # it — the back substitution's coefficients.
      below = for k <- (i + 1)..(n - 1)//1, do: lower |> Enum.at(k) |> Enum.at(i)
      sum = dot(below, Enum.drop(solved, i + 1))

      List.replace_at(solved, i, (Enum.at(y, i) - sum) / (lower |> Enum.at(i) |> Enum.at(i)))
    end)
  end

  # -- the motion matrix, applied rather than multiplied -----------------------

  # `F·M`: each of the first four rows gains the row four below it.
  @spec motion_rows(matrix()) :: matrix()
  defp motion_rows(m) do
    {top, bottom} = Enum.split(m, 4)

    Enum.zip_with(top, bottom, &vec_add/2) ++ bottom
  end

  # `M·Fᵀ` one row at a time — and, for the mean, `F·mean`: each of the first
  # four entries gains the one four along.
  @spec motion_columns([float()]) :: [float()]
  defp motion_columns(row) do
    {top, bottom} = Enum.split(row, 4)

    Enum.zip_with(top, bottom, &+/2) ++ bottom
  end

  # -- matrix arithmetic ------------------------------------------------------

  @spec diagonal([float()]) :: matrix()
  defp diagonal(values) do
    n = length(values)

    values
    |> Enum.with_index()
    |> Enum.map(fn {value, i} -> unit_row(n, i, value) end)
  end

  @spec unit_row(pos_integer(), non_neg_integer(), float()) :: [float()]
  defp unit_row(n, index, value) do
    Enum.map(0..(n - 1), fn j -> if j == index, do: value, else: 0.0 end)
  end

  @spec squared([float()]) :: [float()]
  defp squared(values), do: Enum.map(values, &(&1 * &1))

  @spec transpose(matrix()) :: matrix()
  defp transpose(m), do: Enum.zip_with(m, & &1)

  @spec mat_mul(matrix(), matrix()) :: matrix()
  defp mat_mul(a, b) do
    columns = transpose(b)

    for row <- a, do: for(column <- columns, do: dot(row, column))
  end

  @spec mat_vec(matrix(), [float()]) :: [float()]
  defp mat_vec(m, v), do: Enum.map(m, &dot(&1, v))

  @spec mat_add(matrix(), matrix()) :: matrix()
  defp mat_add(a, b), do: Enum.zip_with(a, b, &vec_add/2)

  @spec mat_sub(matrix(), matrix()) :: matrix()
  defp mat_sub(a, b), do: Enum.zip_with(a, b, &vec_sub/2)

  @spec vec_add([float()], [float()]) :: [float()]
  defp vec_add(a, b), do: Enum.zip_with(a, b, &+/2)

  @spec vec_sub([float()], [float()]) :: [float()]
  defp vec_sub(a, b), do: Enum.zip_with(a, b, &-/2)

  @spec dot([float()], [float()]) :: float()
  defp dot(a, b), do: Enum.zip_reduce(a, b, 0.0, fn x, y, acc -> acc + x * y end)
end
