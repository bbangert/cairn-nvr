defmodule Cairn.Tracker.Reid do
  @moduledoc """
  The appearance arithmetic for Re-ID fusion: dequantization, the rolling
  per-track embedding, and cosine distance.

  The wire carries a person detection's feature as raw bytes — a symmetric
  int8 quantization of a unit-norm vector at the fixed scale 127
  (`docs/plugin-contract.md`). Everything here works in dequantized,
  re-normalized float space: cosine is scale-invariant, but the rolling
  average is not, so vectors are normalized once on the way in and the roll
  re-normalizes its result.

  This module is arithmetic only, `Cairn.Tracker.Bbd`-style: where the
  numbers apply — which pairs, which flag, which exclusions — belongs to
  the stage and the tracker.
  """

  # BoT-SORT's momentum: the rolling embedding keeps 90% of what it was and
  # takes 10% of each new detected appearance. High because single-crop
  # features are noisy (motion blur, partial occlusion) and identity is the
  # slow-moving signal being tracked.
  @momentum 0.9

  # The appearance veto: a pair whose cosine distance exceeds this is
  # refused admission even where geometry admits it. Deliberately loose —
  # the phase-4 spike measured within-identity distance 0.33 ± 0.15 against
  # between-identity 0.39 ± 0.11 on real CCTV crops, distributions that
  # overlap far too much for an aggressive threshold to cut wrong pairs
  # without also cutting right ones. At 0.6 only the clearly-different
  # appearance is refused. Unproven at a better value until the phase-6 E2E
  # measurement; a constant rather than config for the same reason as
  # `@stationary_match_iou` — getting it wrong is a silent identity bug.
  @reid_veto_distance 0.6

  @doc "The admission veto threshold, for the stage and its tests."
  @spec veto_distance() :: float()
  def veto_distance, do: @reid_veto_distance

  @doc """
  Raw wire bytes to a unit-norm float list. `nil` for an empty or
  degenerate (all-zero) vector — a feature that cannot be normalized
  carries no appearance.
  """
  @spec dequant(binary()) :: [float()] | nil
  def dequant(bytes) when is_binary(bytes) do
    vector = for <<component::signed-8 <- bytes>>, do: component / 127
    normalize(vector)
  end

  @doc """
  The rolling per-track embedding: seeded by the first feature, then an
  exponential moving average re-normalized per step. Both inputs are
  unit-norm lists (`dequant/1` output for the detection side).
  """
  @spec roll([float()] | nil, [float()]) :: [float()]
  def roll(nil, fresh), do: fresh

  def roll(rolling, fresh) do
    blended =
      Enum.zip_with(rolling, fresh, fn r, f -> @momentum * r + (1.0 - @momentum) * f end)

    # A blend of unit vectors can only vanish if they were antipodal, which
    # two same-person features never are; falling back to the fresh side
    # keeps the function total anyway.
    normalize(blended) || fresh
  end

  @doc """
  Cosine distance between two unit-norm vectors: 0 identical, 1 orthogonal,
  2 antipodal. Mismatched dimensions — two different embedder models on one
  wire — carry no comparable appearance and return `nil`, like a missing
  side would.
  """
  @spec distance([float()], [float()]) :: float() | nil
  def distance(a, b) when length(a) == length(b) do
    1.0 - (a |> Enum.zip_with(b, &(&1 * &2)) |> Enum.sum())
  end

  def distance(_a, _b), do: nil

  defp normalize(vector) do
    norm = vector |> Enum.map(&(&1 * &1)) |> Enum.sum() |> :math.sqrt()

    if norm > 1.0e-6 do
      Enum.map(vector, &(&1 / norm))
    end
  end
end
