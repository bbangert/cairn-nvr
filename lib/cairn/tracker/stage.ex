defmodule Cairn.Tracker.Stage do
  @moduledoc """
  The behaviour a `Cairn.Tracker` stage implements.

  A stage is a named, composable piece of the tracker's pipeline. This first
  version declares exactly one stage kind — the per-object hook below, run by
  `update_track/3` for every matched or adopted object — because exactly one
  stage exists (`Cairn.Tracker.Stage.Oru`). Batch stages, which see the whole
  assignment rather than one track's update, arrive with the BBD extraction.

  Which stages run is the host's decision, not the stage's: today the list is
  translated from the tracker context's `oru` boolean
  (`per_object_stages/1` in `Cairn.Tracker`), and a listed stage runs
  unconditionally — a stage does not read a feature flag to decide whether to
  act. Profiles later replace that translation with a configured list
  travelling the same plumbing.

  ## The pre-write contract

  `per_object/5` runs at one fixed point inside `update_track/3`: after the
  previous batch's clocks have been read off the record, before this batch's
  writes move them. Two things follow, and both are contract, not convention:

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
  """

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
end
