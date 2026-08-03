defmodule Cairn.Tracker.Kalman do
  @moduledoc """
  ByteTrack's per-track motion filter: an 8-dimensional constant-velocity
  Kalman filter over a box's centre, aspect ratio and height.

  The state is `[cx, cy, a, h, vcx, vcy, va, vh]` — centre, aspect ratio `w/h`,
  height, and the velocity of each — which is DeepSORT's parameterisation and
  the one ByteTrack inherited. Aspect and height rather than width and height
  because a box's shape is far steadier than its size: a person walking towards
  the camera grows in both dimensions at once, and a filter that tracks `a`
  spends none of its process noise re-learning that the person is still
  person-shaped.

  Time is folded into the velocity units: one `predict/1` is one step, whatever
  wall-clock or media interval separates two batches. That is ByteTrack's
  convention and not an approximation this module could improve on locally —
  the velocities are learned in whatever units the caller steps in, so as long
  as a caller steps once per batch the filter is self-consistent. It does mean
  the state is only meaningful relative to that caller's own cadence, and that
  a caller which sometimes steps twice for one batch is telling the filter the
  object moved twice as far.

  ## The cardinal caller rule

  **A predicted box is a matching input only.** It may be handed to an overlap
  test to decide which detection belongs to which track, and that is the whole
  of what it is for. It must never be stored as a track's `bbox`, never written
  to a summary, never emitted on the wire, and never persisted. A prediction is
  this module's guess about where an object would be *if it were still there*,
  which is precisely the question a detection answers and an extrapolation
  cannot; letting one become a track's box would let a filter talk a departed
  object into existence for as long as it kept guessing. `Cairn.Tracker`'s
  stitching already refuses predicted *observations* for that reason (see the
  `Observation.detected?/1` gate in `adopt/4`), and predictions minted here are
  weaker evidence still: nothing outside this module has even claimed to have
  seen them.

  ## Why hand-rolled

  This is a fixed 8x8 problem with a fixed 4-dimensional measurement, and every
  matrix in it is either a constant or a diagonal built from one number. The
  arithmetic that follows is a few dozen lines of list traversal; a generic
  linear-algebra package would bring a dependency, a NIF or a compilation step
  and a general-case API for a problem with no general case in it. Nx in
  particular is a poor trade here: its win is batching many large tensors on an
  accelerator, and per-track 8x8 work in a per-camera process is the shape it
  is worst at.

  The other half of the reason is the noise model. The process and measurement
  noise below are *height-scaled* — a box twice as tall is assumed to move and
  to be measured twice as sloppily, in normalized units — and that tuning is
  the part of a Kalman filter that actually decides whether tracking works.
  Keeping it inline, next to the equations it feeds, is what makes it legible
  and reviewable; behind a package's covariance-matrix argument it would be a
  block of magic numbers assembled somewhere else.

  ## Units

  Boxes are `[x, y, w, h]` **normalized to the frame**, `x, y` the top-left
  corner — the same convention as `Cairn.Tracker.iou/2` and everything else the
  host passes around. Widths and heights are fractions of the frame and so lie
  in `0..1`; a corner is not bounded the same way, because a detection may
  legally overhang the frame edge and an object halfway out of shot does.

  `predicted_bbox/1` keeps to exactly that. It returns a box whose width and
  height are positive and no larger than the frame, and whose origin is free.
  The dimensions are bounded because the only thing that consumes a prediction
  is overlap arithmetic, which needs a box with area. The origin is not,
  because a prediction's whole job is to follow the object: an object walking
  out of shot is somewhere the frame does not contain, and sliding its box back
  inside would make the filter insist it was still at the edge — its overlap
  with whatever is really there would snap to the border instead of decaying to
  nothing as it leaves, and a track whose own box overhangs the edge would stop
  matching itself.
  """

  # ByteTrack's shipped weights, unchanged from DeepSORT: position noise at
  # 1/20 of the box height, velocity noise at 1/160 of it. They are stock
  # values, not something measured against this project's footage, and the
  # tests below are written against the behaviour they produce — a change to
  # either weight is a change to how far a coasted box drifts before an overlap
  # test sees it, so it belongs with a measurement rather than on its own.
  @std_weight_position 1 / 20
  @std_weight_velocity 1 / 160

  # The floor for anything that must stay positive: the aspect ratio and height
  # in the state, and the width and height of an emitted box. Small enough to
  # be indistinguishable from zero at any frame size (a millionth of a frame
  # dimension is a fraction of a pixel), large enough that dividing a
  # frame-normalized length by it yields about a million rather than an
  # infinity.
  @min_dim 1.0e-6

  @typedoc "A frame-normalized `[x, y, w, h]` box."
  @type bbox :: [number()]

  @typedoc "The 4-vector `[cx, cy, a, h]` a box is observed as."
  @type measurement :: [float()]

  @typedoc "A dense matrix as rows of floats."
  @type matrix :: [[float()]]

  @typedoc """
  The filter's state: the 8-vector mean `[cx, cy, a, h, vcx, vcy, va, vh]` and
  its 8x8 covariance.
  """
  @type t :: %__MODULE__{mean: [float()], covariance: matrix()}

  @enforce_keys [:mean, :covariance]
  defstruct [:mean, :covariance]

  @doc """
  A filter seeded from the first box an object was observed at.

  Velocities start at zero — one box says nothing about motion — and the
  initial covariance says how much that zero is to be believed. Its diagonal is
  height-scaled like the running noise, at ByteTrack's multipliers: twice the
  position weight for the observed quantities and ten times the velocity weight
  for the unobserved ones, so the first few updates can move the velocity
  estimate a long way without the filter treating that as a surprise.

  The two constants in it are the two quantities that are not lengths. Aspect
  ratio gets a fixed `1.0e-2` because its uncertainty does not scale with the
  box's height, and its velocity a fixed `1.0e-5` because a real object's shape
  changes slowly whatever size it is on screen.
  """
  @spec init(bbox()) :: t()
  def init(bbox) do
    [cx, cy, a, h] = to_measurement(bbox)

    position_std = 2 * @std_weight_position * h
    velocity_std = 10 * @std_weight_velocity * h

    stds = [
      position_std,
      position_std,
      1.0e-2,
      position_std,
      velocity_std,
      velocity_std,
      1.0e-5,
      velocity_std
    ]

    %__MODULE__{
      mean: [cx, cy, a, h, 0.0, 0.0, 0.0, 0.0],
      covariance: diagonal(squared(stds))
    }
  end

  @doc """
  One step of the constant-velocity motion model: every quantity advances by
  its own velocity, the velocities themselves are unchanged, and the covariance
  grows by one step's process noise.

  Growth is the point. A track nothing has detected this batch is carried
  forward by repeated `predict/1` with no `update/2`, and each call both moves
  the box along its last known heading and widens the filter's own admission of
  how little it now knows — which is what stops a long coast from being
  mistaken for knowledge.
  """
  @spec predict(t()) :: t()
  def predict(%__MODULE__{mean: mean, covariance: covariance}) do
    # The height the noise is scaled by is the one the filter currently
    # believes, read before the step moves it. Scaling by the post-step height
    # would let a shrinking box quietly shrink its own process noise on the
    # same step it shrank, compounding a bad estimate into a confident one.
    height = Enum.at(mean, 3)
    motion = motion_matrix()

    covariance =
      motion
      |> mat_mul(covariance)
      |> mat_mul(transpose(motion))
      |> mat_add(process_noise(height))

    %__MODULE__{mean: clamp_state(mat_vec(motion, mean)), covariance: covariance}
  end

  @doc """
  The standard Kalman measurement update against an observed box.

  The measurement is `[cx, cy, a, h]`, the first four states, so the
  measurement matrix selects them and the innovation is simply how far the
  observation sits from where the filter expected it. What the gain does with
  that is the whole of the filter's judgement: a state the covariance says is
  well known moves little, one it says is barely known moves nearly all the
  way to the observation.

  The posterior covariance is symmetrized afterwards. `(I - KH)P` is symmetric
  in exact arithmetic and only *nearly* symmetric in floating point, and over
  the thousands of updates a long-lived track accumulates that drift is the
  usual way a hand-rolled filter ends up with a covariance it can no longer
  invert. Averaging with the transpose costs one pass and removes the failure
  mode entirely.
  """
  @spec update(t(), bbox()) :: t()
  def update(%__MODULE__{mean: mean, covariance: covariance}, bbox) do
    height = Enum.at(mean, 3)
    observation = measurement_matrix()
    observation_t = transpose(observation)

    innovation_covariance =
      observation
      |> mat_mul(covariance)
      |> mat_mul(observation_t)
      |> mat_add(measurement_noise(height))

    gain =
      covariance
      |> mat_mul(observation_t)
      |> mat_mul(invert(innovation_covariance))

    innovation = vec_sub(to_measurement(bbox), mat_vec(observation, mean))
    residual = mat_sub(identity(8), mat_mul(gain, observation))

    %__MODULE__{
      mean: clamp_state(vec_add(mean, mat_vec(gain, innovation))),
      covariance: residual |> mat_mul(covariance) |> symmetrize()
    }
  end

  @doc """
  The filter's current estimate of how fast the box's centre is moving, in
  frame widths and heights per step.

  This is the readout the stillness machinery wants: an object whose filtered
  velocity has decayed to nothing is holding still in a way that a
  frame-to-frame box comparison, which sees every pixel of detector jitter as
  motion, cannot tell you.
  """
  @spec velocity(t()) :: {float(), float()}
  def velocity(%__MODULE__{mean: mean}) do
    {Enum.at(mean, 4), Enum.at(mean, 5)}
  end

  @doc """
  Where the filter currently believes the box is, as a frame-normalized
  `[x, y, w, h]` with positive, bounded dimensions and a free origin.

  Subject to the cardinal rule in the module doc: this is a matching input, not
  a box any caller may store or emit.

  Bounding the dimensions is not cosmetic. `w` comes out of the state as
  `a * h`, a product of two estimates either of which a run of bad measurements
  can drive towards zero, and what consumes this box is overlap arithmetic that
  assumes a box with area — `Cairn.Tracker.iou/2` returns a flat `0.0` for
  anything with none, so a degenerate prediction would quietly match nothing
  rather than fail where it could be seen. Width and height are therefore
  floored away from zero and capped at the frame, and that is the whole of what
  the arithmetic downstream needs.

  The corner is left exactly where the state puts it, which is the other half
  of the same decision `clamp_state/1` makes: the centre is deliberately free
  to leave the frame, and pinning the box back inside at the moment it is
  handed out would undo that at the one point where anything reads it. A
  prediction that has followed a departing object out of shot overlaps the
  in-frame boxes less and less until it overlaps nothing, which is the right
  end for a track of something that has gone; a pinned one would sit against
  the border claiming otherwise. It matters for arrivals too — a detection is
  allowed to overhang the frame edge, so a track holding such a box has to be
  able to match its own prediction.
  """
  @spec predicted_bbox(t()) :: [float()]
  def predicted_bbox(%__MODULE__{mean: [cx, cy, a, h | _velocities]}) do
    height = clamp_dimension(h)
    width = clamp_dimension(a * height)

    [cx - width / 2, cy - height / 2, width, height]
  end

  # -- state and box conversions ----------------------------------------------

  # `[x, y, w, h]` as the filter sees it. The floors are what make the aspect
  # ratio safe to compute: a detector that emits a zero-height box — or the
  # host that normalized one to zero after rounding — would otherwise divide by
  # zero here rather than at some later point where the state is already ruined.
  @spec to_measurement(bbox()) :: measurement()
  defp to_measurement([x, y, w, h]) do
    width = max(w * 1.0, @min_dim)
    height = max(h * 1.0, @min_dim)

    [x + width / 2, y + height / 2, width / height, height]
  end

  # Aspect ratio and height are lengths and a ratio of lengths: neither has a
  # meaning at or below zero, and both appear in denominators. The filter's
  # arithmetic has no notion of that — a large enough negative `vh` sustained
  # over enough predict-only steps walks `h` straight through zero — so the
  # constraint is imposed here, on every path that writes a mean.
  #
  # Only the two shape states are clamped. The centre is deliberately left free
  # to leave the frame: an object walking out of shot has a centre outside
  # `0..1` and pinning it at the edge would make the filter insist the object
  # is still there. `predicted_bbox/1` carries that freedom all the way to the
  # caller — it bounds the two dimensions, which overlap arithmetic needs, and
  # leaves the corner alone, which is the only reason the freedom here is worth
  # anything.
  @spec clamp_state([float()]) :: [float()]
  defp clamp_state([cx, cy, a, h, vcx, vcy, va, vh]) do
    [cx, cy, max(a, @min_dim), max(h, @min_dim), vcx, vcy, va, vh]
  end

  @spec clamp_dimension(float()) :: float()
  defp clamp_dimension(value), do: value |> max(@min_dim) |> min(1.0)

  # -- noise ------------------------------------------------------------------

  # One step's process noise: how much the model expects the truth to have
  # drifted away from the constant-velocity assumption. Height-scaled, because
  # a box that fills the frame is a nearby object whose normalized position
  # changes fast, while a box a few percent tall is far away and barely moves
  # between frames even when the object is running.
  @spec process_noise(float()) :: matrix()
  defp process_noise(height) do
    position_std = @std_weight_position * height
    velocity_std = @std_weight_velocity * height

    diagonal(
      squared([
        position_std,
        position_std,
        1.0e-2,
        position_std,
        velocity_std,
        velocity_std,
        1.0e-5,
        velocity_std
      ])
    )
  end

  # How much the detector is distrusted. Same height scaling for the same
  # reason; the aspect-ratio term is a fixed `1.0e-1`, an order of magnitude
  # looser than the process noise's `1.0e-2`, which says the filter's own model
  # of a box's shape is steadier than any single detection of it.
  @spec measurement_noise(float()) :: matrix()
  defp measurement_noise(height) do
    position_std = @std_weight_position * height

    diagonal(squared([position_std, position_std, 1.0e-1, position_std]))
  end

  # -- fixed model matrices ---------------------------------------------------

  # 8x8, identity plus the velocity coupling: `x_i` gains `v_i` per step, the
  # velocities carry unchanged. The `dt` of the usual formulation is 1 by the
  # convention in the module doc, so it appears nowhere.
  @spec motion_matrix() :: matrix()
  defp motion_matrix do
    Enum.map(0..7, &motion_row/1)
  end

  @spec motion_row(non_neg_integer()) :: [float()]
  defp motion_row(i) do
    Enum.map(0..7, fn j -> if j == i or j == i + 4, do: 1.0, else: 0.0 end)
  end

  # 4x8, selecting the four observed states. Velocity is never measured — it is
  # only ever inferred from how the observed states move — which is the whole
  # reason the filter is worth having.
  @spec measurement_matrix() :: matrix()
  defp measurement_matrix do
    Enum.map(0..3, &unit_row(8, &1, 1.0))
  end

  # -- matrix arithmetic ------------------------------------------------------
  #
  # Plain lists of lists of floats. Every matrix here is 8x8, 8x4, 4x8 or 4x4,
  # so nothing below is worth specialising by size and no dimension is ever
  # checked: a mismatch would be a bug in this module rather than a runtime
  # condition, and the traversals below would silently truncate or produce a
  # wrong-shaped result rather than raise on one.

  @spec identity(pos_integer()) :: matrix()
  defp identity(n) do
    Enum.map(0..(n - 1), &unit_row(n, &1, 1.0))
  end

  @spec diagonal([float()]) :: matrix()
  defp diagonal(values) do
    n = length(values)

    values
    |> Enum.with_index()
    |> Enum.map(fn {value, i} -> unit_row(n, i, value) end)
  end

  # A row of `n` zeroes with `value` at `index` — the whole of what a diagonal
  # or a selector matrix is made of. The motion matrix is neither, and builds
  # its rows in `motion_row/1`.
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

  @spec symmetrize(matrix()) :: matrix()
  defp symmetrize(m) do
    Enum.zip_with(m, transpose(m), fn row, column ->
      Enum.zip_with(row, column, &((&1 + &2) / 2))
    end)
  end

  # Gauss-Jordan with partial pivoting on `[m | I]`, returning the right half.
  #
  # The only matrix ever inverted here is the 4x4 innovation covariance
  # `HPH' + R`, which is positive definite as long as `R` is — and `R` is a
  # diagonal of squared, strictly positive standard deviations, since the
  # height feeding it is clamped away from zero. So this is never asked to
  # invert a singular matrix in practice, and partial pivoting is here for
  # conditioning rather than for survival: `R`'s smallest entries are tiny for
  # a short box, and eliminating on an unpivoted row would lose most of the
  # precision in the gain.
  @spec invert(matrix()) :: matrix()
  defp invert(m) do
    n = length(m)

    augmented = Enum.zip_with(m, identity(n), &(&1 ++ &2))

    0..(n - 1)
    |> Enum.reduce(augmented, &eliminate_column(&2, &1))
    |> Enum.map(&Enum.drop(&1, n))
  end

  # One Gauss-Jordan step: promote the largest remaining candidate in this
  # column to the pivot row, scale it to a leading 1, and clear the column from
  # every other row. Rows above `column` are already reduced and keep their
  # position, which is what makes the result come back in the original order.
  @spec eliminate_column(matrix(), non_neg_integer()) :: matrix()
  defp eliminate_column(rows, column) do
    {settled, candidates} = Enum.split(rows, column)
    {pivot, rest} = take_pivot(candidates, column)

    scaled = scale_row(pivot, column)
    clear = &clear_column(&1, scaled, column)

    Enum.map(settled, clear) ++ [scaled | Enum.map(rest, clear)]
  end

  # The remaining row with the largest magnitude in this column, and the rest
  # in their original order. Selection is by index rather than by value:
  # `Enum.max_by/2` keeps the first maximal element, so ties resolve to the
  # topmost row and the inversion is deterministic, and deleting by index
  # cannot remove a different row that happens to compare equal.
  @spec take_pivot(matrix(), non_neg_integer()) :: {[float()], matrix()}
  defp take_pivot(rows, column) do
    {_row, index} =
      rows
      |> Enum.with_index()
      |> Enum.max_by(fn {row, _index} -> abs(Enum.at(row, column)) end)

    {Enum.at(rows, index), List.delete_at(rows, index)}
  end

  @spec scale_row([float()], non_neg_integer()) :: [float()]
  defp scale_row(row, column) do
    pivot = Enum.at(row, column)
    # A zero pivot means the matrix is singular, which the comment on
    # `invert/1` explains cannot happen to the one matrix this inverts. If the
    # impossible does arrive, dividing by the floor yields an enormous but
    # finite gain rather than the NaN that would poison every later step of the
    # track's state and never wash out.
    divisor = if pivot == 0.0, do: @min_dim, else: pivot

    Enum.map(row, &(&1 / divisor))
  end

  @spec clear_column([float()], [float()], non_neg_integer()) :: [float()]
  defp clear_column(row, pivot_row, column) do
    factor = Enum.at(row, column)

    Enum.zip_with(row, pivot_row, fn value, pivot -> value - factor * pivot end)
  end
end
