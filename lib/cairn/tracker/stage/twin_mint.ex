defmodule Cairn.Tracker.Stage.TwinMint do
  @moduledoc """
  The cold-start twin gate: one object arriving as two boxes mints once.

  The same drop rule as `suppress_duplicates/4` with its last candidate
  removed: where `Cairn.Tracker.duplicate_of/2` has no live track to read a
  leftover box as, the other boxes this batch is about to mint for are what
  is left to weigh it against. Two same-label boxes overlapping by the
  duplicate-suppression threshold, neither of which took a track, are one
  object arriving for the first time, and minting for both is how that
  object is born already twinned.

  No ordering of `suppress_duplicates/4` reaches this case: the track it
  would weigh against is minted in `apply_assignments/5`, after every pass
  in `assign/3` has run, so on the batch an object first appears in there is
  nothing live for either of its boxes to be a duplicate of. Nor does a
  later batch get the case back — once both boxes have minted, the
  association passes match one to each twin, and a matched box is never a
  leftover, so suppression is never offered either of them again. The pair
  is self-sustaining from its first batch, which is why the drop has to
  happen on that batch or not at all.

  ## Gating — the one default-ON stage

  A listed stage runs unconditionally, as ever — but unlike `bbd`/`oru`,
  the `twin_mint` flag *defaults to listed* (`minting_stages/1` in
  `Cairn.Tracker`): the gate is behavior every existing deployment already
  has, so absence preserves it. `twin_mint: false` is the deliberate
  opt-out for NMS-free detectors, whose redundant band boxes make
  legitimate close same-label pairs common enough that the gate would eat
  real objects.

  The default belongs to the **boolean** path. A camera whose plugin group
  carries a hardware profile is listed by presence alone — a profile that
  does not name `twin_mint:` delists the gate, which is what `qcs6490.yml`
  does and why that file argues the case in its own comments: this stage
  exists *because* an NMS-free head slipped a double box (the incident
  above), so turning it off for one is a trade nothing has measured.

  ## Placement

  `constraints/0` pins this last at its insertion point: it weighs the
  *final* mint set, so anything that could still spend an index must have
  run first — a stage after it could resurrect exactly the twin this
  dropped, or drop a box this already weighed, either way judging a mint
  set that no longer exists.
  """

  @behaviour Cairn.Tracker.Stage

  alias Cairn.Tracker

  @impl true
  def call(batch, _params) do
    %{batch | assignment: suppress_twin_mints(batch.indexed, batch.assignment)}
  end

  @impl true
  def constraints, do: %{last_at_point: true}

  # A would-be mint is an index with no entry in `assignments`, which is
  # `apply_object/6`'s own reading of the map and the whole definition of the
  # mint set. Everything else has therefore already been spent under a track
  # id or a `:drop` — matched in either stage, adopted, suppressed against a
  # live track, or spent as a stage-two leftover — so a box that could still
  # have done something other than mint is not in here to compete, and the
  # only answer this can change is `:new` to `:drop`.
  #
  # Best score first, ties by batch index, and each box is weighed against
  # the ones already kept: the box kept is the one that goes on to mint and
  # the rest are dropped, marking nothing seen, because there is no track to
  # mark. The sort key is total on the house rule the tracker's `iou_pairs/3`
  # keys are written to — two equally-scored boxes are separated by the
  # earlier one in the batch and never by which order a sort happened to
  # leave them in. The boxes not yet reached are no part of the test either,
  # which is what keeps a row of overlapping neighbours from collapsing to
  # one: what a box is weighed against is the ones already *kept*, so it
  # mints whatever it overlaps that was dropped.
  defp suppress_twin_mints(indexed, assignments) do
    minting =
      for {object, index} <- indexed, not Map.has_key?(assignments, index), do: {index, object}

    minting
    |> Enum.sort_by(fn {index, object} -> {-object.score, index} end)
    |> Enum.reduce({[], assignments}, fn {index, object}, {kept, assignments} ->
      case Tracker.duplicate_of(kept, object) do
        nil -> {[{index, object} | kept], assignments}
        _twin -> {kept, Map.put(assignments, index, :drop)}
      end
    end)
    |> elem(1)
  end
end
