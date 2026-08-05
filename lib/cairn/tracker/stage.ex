defmodule Cairn.Tracker.Stage do
  @moduledoc """
  The behaviour a `Cairn.Tracker` stage implements.

  A stage is a named, composable piece of the tracker's pipeline, in one of
  two kinds — and the kind is declared by which callback the module exports,
  not by anything a stage list author writes:

    * **Batch stages** export `c:call/2` and run at a named insertion point
      inside `assign/3`, over the whole `Cairn.Tracker.Batch` accumulator.
      `Cairn.Tracker.Stage.Bbd` is one.
    * **Per-object stages** export `c:per_object/5` and run inside
      `update_track/3`, once per matched or adopted object.
      `Cairn.Tracker.Stage.Oru` is one.

  Which stages run is the host's decision, not the stage's: today the lists
  are translated from the tracker context's `bbd`/`oru` booleans
  (`batch_stages/1` and `per_object_stages/1` in `Cairn.Tracker`), and a
  listed stage runs unconditionally — a stage does not read a feature flag
  to decide whether to act. Profiles later replace that translation with a
  configured list travelling the same plumbing, validated by
  `validate_lists/1` below.

  ## Substrate, not stages

  The passes `assign/3` always runs — partition, prediction, the two IoU
  association passes, adoption, leftover spending, duplicate suppression —
  are **not** wrapped as stages. The ordering-constraint extraction behind
  this design (stage-chain-feasibility research, C1–C13) found zero legal
  reordering freedom among them: wrapping them would add public API surface
  with no profile-usable freedom behind it. Stages exist where composition
  is real — admissions after an association pass, per-object updates at the
  hook — and the substrate stays fixed code.

  ## The pre-write contract (per-object stages)

  `per_object/5` runs at one fixed point inside `update_track/3`: after the
  previous batch's clocks have been read off the record, before this batch's
  writes move them. Two things follow, and both are contract, not
  convention:

    * **What a stage reads is pre-write state.** `bbox` is still the last box
      the track was really observed at and `last_matched_ms` still dates it —
      the two ends of whatever gap a stage measures. The closing detection's
      own writes land after every stage has run.
    * **A stage edits the copy it is handed and returns it — never
      `tracker.objects`.** `apply_object/6` diffs the record as it stood
      before this batch against the updated one to emit lifecycle transitions
      (`transition/3`), so an edit written into `tracker.objects` directly
      would already be present on both sides of that diff and no event would
      go out. That silence is not free downstream: `CairnWeb.TrackMoments`
      reads a stationary run as a `became_stationary` closed by the next
      `started_moving`, and `Cairn.TrackPath`'s keyframe rule leans on the
      same pairing — a flag cleared invisibly leaves the run rendering as
      still open across a stretch the tracker already decided it was not.

  ## Constraints

  A stage may export `c:constraints/0` to declare where it may legally sit;
  `validate_lists/1` enforces them. The vocabulary is small on purpose —
  each key exists because a real stage needs it, not speculatively:

    * `adjacent_after: :iou_association` — the stage must run immediately
      after an IoU association pass, nothing that spends objects or tracks
      between them. This is what keeps an admission stage's seeded reduce
      bit-identical to an inline interleave (`Cairn.Tracker.Batch.spend/2`).
    * `paired_across_association: true` — the stage appears at both
      association insertion points or neither. An admission that ran for
      only one evidence tier would be a different algorithm than the one
      the soak measured.
  """

  alias Cairn.Tracker.Batch

  @typedoc """
  The tracker's internal per-track record — the plain map built by
  `new_track/3` in `Cairn.Tracker` and stored in `tracker.objects`. Not
  `Cairn.Track`, which is the public summary derived from it.
  """
  @type tracked :: map()

  @typedoc "One observation's object, as handed to `Cairn.Tracker.track/3`."
  @type object :: %{
          required(:label) => String.t(),
          required(:score) => number(),
          required(:bbox) => [number()],
          optional(any()) => any()
        }

  @typedoc "Stage parameters, from the stage list entry. Empty until profiles."
  @type params :: map()

  @typedoc """
  The stage lists the tracker actually runs, one per attachment point. The
  transitional boolean translation builds these; profiles will.
  """
  @type lists :: %{
          association_one: [{module(), params()}],
          association_two: [{module(), params()}],
          per_object: [{module(), params()}]
        }

  @doc """
  One batch-stage pass over the accumulator, at the insertion point the
  stage list placed it.

  A batch stage reads what `Cairn.Tracker.Batch` documents as public and
  returns the batch with its own contribution folded in — for an admission
  stage, an `assignment` extended through `Cairn.Tracker.Batch.spend/2` and
  nothing else.
  """
  @callback call(Batch.t(), params()) :: Batch.t()

  @doc """
  One track's pre-write update, between the clock reads and the field writes
  of `update_track/3`.

  `detected?` is `Cairn.Observation.detected?/1`'s answer for this object — a
  real detection closes gaps and steps filters; a seeded re-report does
  neither, and a stage must weigh it the same way the host does.

  Stages are folded in list order, each handed the previous stage's result.
  """
  @callback per_object(
              tracked(),
              object(),
              detected? :: boolean(),
              Cairn.Tracker.context(),
              params()
            ) :: tracked()

  @doc "Placement constraints, enforced by `validate_lists/1`. See the moduledoc."
  @callback constraints() :: map()

  @optional_callbacks call: 2, per_object: 5, constraints: 0

  @doc """
  Validates stage lists against each stage's declared kind and constraints.

  Returns `:ok` or `{:error, reason}` with a sentence naming the stage and
  the rule — the shape `Cairn.Config`'s `add_error/2` contract wants, since
  config load is where this moves once profiles supply the lists (a failed
  profile is a failed config load; the tracker has no error channel).

  What it rejects:

    * a module in a batch position that does not export `call/2`, or in the
      per-object list without `per_object/5` — the kind *is* the exported
      callback, so a per-object stage in a batch slot is not a preference
      but a stage that would never run where the list claims it does;
    * an `adjacent_after: :iou_association` stage anywhere but the head of
      an association list — a spending stage between the association pass
      and its companion changes which pairs are free, which is a different
      algorithm, not a reordering;
    * a `paired_across_association: true` stage present at one association
      point but not the other.
  """
  @spec validate_lists(lists()) :: :ok | {:error, String.t()}
  def validate_lists(lists) do
    with :ok <- validate_kinds(lists.association_one, :batch, "association one"),
         :ok <- validate_kinds(lists.association_two, :batch, "association two"),
         :ok <- validate_kinds(lists.per_object, :per_object, "per-object"),
         :ok <- validate_adjacency(lists.association_one, "association one"),
         :ok <- validate_adjacency(lists.association_two, "association two") do
      validate_pairing(lists)
    end
  end

  defp validate_kinds(list, kind, where) do
    {callback, arity} = if kind == :batch, do: {:call, 2}, else: {:per_object, 5}

    Enum.find_value(list, :ok, fn {module, _params} ->
      kind_error(module, {callback, arity}, kind, where)
    end)
  end

  defp kind_error(module, {callback, arity}, kind, where) do
    case Code.ensure_loaded(module) do
      {:module, ^module} ->
        unless function_exported?(module, callback, arity) do
          {:error,
           "#{inspect(module)} is listed at the #{where} point but does not " <>
             "export #{callback}/#{arity} — it is not a #{kind} stage and would never run there"}
        end

      {:error, reason} ->
        # Distinct from the wrong-kind message: a typo'd module name is a
        # different mistake than a stage in the wrong slot, and the error
        # should say which one was made.
        {:error,
         "#{inspect(module)} is listed at the #{where} point but cannot be " <>
           "loaded (#{inspect(reason)})"}
    end
  end

  defp validate_adjacency(list, where) do
    list
    |> Enum.with_index()
    |> Enum.find_value(:ok, fn {{module, _params}, position} ->
      if constraint(module, :adjacent_after) == :iou_association and position != 0 do
        {:error,
         "#{inspect(module)} must run immediately after the #{where} IoU pass " <>
           "(adjacent_after: :iou_association), but #{position} stage(s) precede it"}
      end
    end)
  end

  defp validate_pairing(lists) do
    paired = fn list ->
      for {module, _params} <- list,
          constraint(module, :paired_across_association) == true,
          into: MapSet.new(),
          do: module
    end

    one = paired.(lists.association_one)
    two = paired.(lists.association_two)

    case MapSet.symmetric_difference(one, two) |> MapSet.to_list() do
      [] ->
        :ok

      [module | _rest] ->
        {:error,
         "#{inspect(module)} declares paired_across_association and must appear " <>
           "at both association points or neither"}
    end
  end

  # Every module reaching here already passed `validate_kinds/3`, so it loads;
  # the `match?/2` keeps that assumption local rather than load-order-shaped.
  defp constraint(module, key) do
    if match?({:module, _module}, Code.ensure_loaded(module)) and
         function_exported?(module, :constraints, 0) do
      Map.get(module.constraints(), key)
    end
  end
end
