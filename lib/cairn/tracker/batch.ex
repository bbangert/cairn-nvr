defmodule Cairn.Tracker.Batch do
  @moduledoc """
  One observation batch moving through `Cairn.Tracker`'s association pipeline
  — the accumulator every batch stage (`c:Cairn.Tracker.Stage.call/2`) is
  handed and returns.

  **Every field here is public stage API surface.** A field a stage may read
  is a compatibility promise, which is why the struct carries exactly what
  the substrate passes already share and nothing speculative:

    * `tracker` — the `Cairn.Tracker` struct as of this point in the batch.
      Stages read it; the substrate's own passes (adoption, suppression) are
      what write it.
    * `context` — the observation's `t:Cairn.Tracker.context/0`. Read-only.
    * `indexed` — the full batch as `[{object, index}]`, the indices being
      what `assignment` is keyed by.
    * `above_floor` / `below_floor` — `indexed` split at the camera's
      evidence floor; stage one associates the first, stage two the second
      (see `assign/3`'s doc in `Cairn.Tracker`).
    * `candidates` — `[{id, tracked, predicted_box}]`, one entry per live
      track, predictions computed once for the whole batch. Built before
      adoption runs, so a track revived out of suspension is never in it.
    * `assignment` — the triple every association-region pass shares: the
      assignment map (object index → track id | `:drop`), the object
      indices spent, and the track ids taken. Threading one accumulator
      through every pass is what makes "each object and each track used
      once" hold *across* passes and not only within one; `spend/2` below
      is the one way anything adds to it. The substrate's suppression pass
      **collapses the triple to the bare map** — from there on the spent
      sets have no meaning, and what a stage at the minting point (or
      `apply_assignments/5`) reads is `%{index => id | :drop}` alone.
    * `adopted` — the track ids adoption revived this batch, for the
      `:adopted` events `apply_assignments/5` emits.
    * `association` — which association pass most recently ran (`:one` |
      `:two`, `nil` before either). An admission companion like
      `Cairn.Tracker.Stage.Bbd` keys its object slice on this rather than
      guessing: `:one` admits from `above_floor`, `:two` from `below_floor`.
  """

  alias Cairn.Tracker

  @typedoc "The assignment map alone, as the minting point and `apply_assignments/5` read it."
  @type assignments :: %{optional(non_neg_integer()) => String.t() | :drop}

  @type assignment :: {assignments(), MapSet.t(), MapSet.t()}

  @type t :: %__MODULE__{
          tracker: Tracker.t(),
          context: Tracker.context(),
          indexed: [{map(), non_neg_integer()}],
          above_floor: [{map(), non_neg_integer()}],
          below_floor: [{map(), non_neg_integer()}],
          candidates: [{String.t(), map(), Tracker.bbox()}],
          assignment: assignment() | assignments(),
          adopted: [String.t()],
          association: :one | :two | nil
        }

  defstruct tracker: nil,
            context: nil,
            indexed: [],
            above_floor: [],
            below_floor: [],
            candidates: [],
            assignment: {%{}, MapSet.new(), MapSet.new()},
            adopted: [],
            association: nil

  @doc """
  Greedily spends an ordered pair list into the assignment triple.

  `pairs` is `[{cost, object_index, track_id}]`, best first — the caller
  owns the ordering and the cost's meaning (IoU descending for the live
  pass, BBD distance ascending for its companion). A pair whose object or
  track is already spent is skipped, and that bookkeeping is the whole of
  how two admissions compose: `Enum.reduce(a ++ b, acc, f)` is
  `Enum.reduce(b, Enum.reduce(a, acc, f), f)`, so an admission stage that
  spends its own sorted pairs *seeded with the previous pass's triple* is
  bit-identical to having appended them — provided nothing that spends
  objects or tracks ran in between, which is exactly the adjacency
  constraint `Cairn.Tracker.Stage.Bbd` declares.
  """
  @spec spend(assignment(), [{term(), non_neg_integer(), String.t()}]) :: assignment()
  def spend(assignment, pairs) do
    Enum.reduce(pairs, assignment, fn {_cost, index, id}, {assignments, objects, tracks} = acc ->
      if MapSet.member?(objects, index) or MapSet.member?(tracks, id) do
        acc
      else
        {Map.put(assignments, index, id), MapSet.put(objects, index), MapSet.put(tracks, id)}
      end
    end)
  end
end
