defmodule Cairn.Tracker.Stage.OruTest do
  @moduledoc """
  Direct unit tests for `Cairn.Tracker.Stage.Oru`'s `per_object/5`.

  The integrated behavior — the stage reached through `Tracker.track/3` with
  the `oru` flag, events and all — is pinned by `tracker_test.exs`'s
  "rebuilding a filter across a gap" describe block and by the golden replay
  suite; those stay where they are for the strangler window. What this file
  adds is the stage's own contract at its own boundary: the replay window's
  edges, the `detected?` refusal, the adoption reading, and the parts of the
  `Cairn.Tracker.Stage` contract a single-stage world can exercise (params
  opacity, behaviour conformance). Fold *order* across multiple per-object
  stages has no test yet and cannot have one — `per_object_stages/1`
  translates one boolean into at most one stage — so that property is pinned
  the day a second per-object stage or the profile stage list exists.
  """

  use ExUnit.Case, async: true

  alias Cairn.Tracker.Stage
  alias Membrane.MOTTracker.Kalman

  @anchor [0.30, 0.30, 0.20, 0.40]
  # Centre displaced 0.10 in x from @anchor, same size: far past what any
  # in-window gap's drift allowance admits at these settings.
  @moved [0.40, 0.30, 0.20, 0.40]
  # Centre displaced 0.01: inside the allowance an 8 s gap of a 10 s settle
  # window buys (0.1 * h=0.4 / 10_000 ms/settle * 8_000 ms = 0.032).
  @nudged [0.31, 0.30, 0.20, 0.40]

  # The fields the stage reads and writes, pre-write values. A live track
  # carries a filter; an adoption carries `kalman: nil` (see the nil-filter
  # chain in `revive/3` and the stage's `per_object/5` doc).
  defp tracked(overrides) do
    Map.merge(
      %{
        kalman: Kalman.init(@anchor),
        bbox: @anchor,
        last_matched_ms: 0,
        stationary: false,
        stationary_since: nil
      },
      Map.new(overrides)
    )
  end

  defp object(bbox), do: %{label: "person", score: 0.9, bbox: bbox}

  # The two context keys the stage reads: the gap's far end and the settle
  # window its drift allowance scales on.
  defp context(at_ms), do: %{at_ms: at_ms, stationary_after_ms: 10_000}

  defp run(tracked, bbox, detected? \\ true, at_ms \\ 3_000, params \\ %{}) do
    Stage.Oru.per_object(tracked, object(bbox), detected?, context(at_ms), params)
  end

  describe "the replay window" do
    test "an in-window gap rebuilds the filter across it, exactly refit's way" do
      out = run(tracked([]), @moved)

      # 3_000 ms at the 500 ms cadence is six steps; the rebuild is
      # deterministic, so equality against a direct refit is exact.
      assert out.kalman == Kalman.refit(@anchor, @moved, 6)
      refute out.kalman == tracked([]).kalman
    end

    test "the window's edges are inclusive at both ends" do
      assert run(tracked([]), @moved, true, 1_000).kalman == Kalman.refit(@anchor, @moved, 2)
      assert run(tracked([]), @moved, true, 10_000).kalman == Kalman.refit(@anchor, @moved, 20)
    end

    test "gaps outside the window leave the record untouched" do
      for at_ms <- [999, 10_001] do
        assert run(tracked([]), @moved, true, at_ms) == tracked([])
      end
    end

    test "a seeded re-report never replays, whatever the gap" do
      # `detected?` false is the refusal itself — same in-window gap as above.
      assert run(tracked([]), @moved, false) == tracked([])
    end
  end

  describe "the adoption reading" do
    test "an in-window displacement past the drift floor clears the flag" do
      adoption =
        tracked(kalman: nil, stationary: true, stationary_since: ~U[2026-07-26 12:00:00Z])

      out = run(adoption, @moved, true, 8_000)

      refute out.stationary
      assert out.stationary_since == nil
      # The rebuild happens too — clearing and replaying are one visit.
      assert out.kalman == Kalman.refit(@anchor, @moved, 16)
    end

    test "a displacement under the floor keeps the flag it was suspended with" do
      adoption =
        tracked(kalman: nil, stationary: true, stationary_since: ~U[2026-07-26 12:00:00Z])

      out = run(adoption, @nudged, true, 8_000)

      assert out.stationary
      assert out.stationary_since == ~U[2026-07-26 12:00:00Z]
      assert out.kalman == Kalman.refit(@anchor, @nudged, 16)
    end

    test "a moving track's adoption skips the reading but still replays" do
      adoption = tracked(kalman: nil, stationary: false)
      out = run(adoption, @moved, true, 8_000)

      refute out.stationary
      assert out.kalman == Kalman.refit(@anchor, @moved, 16)
    end
  end

  describe "the stage contract" do
    test "params are opaque to this stage" do
      # The behaviour threads a params map per stage-list entry; Oru takes
      # none yet, and whatever arrives must not change its answer.
      assert run(tracked([]), @moved) ==
               run(tracked([]), @moved, true, 3_000, %{tuning: :ignored, depth: 9})
    end

    test "the module declares the Stage behaviour" do
      behaviours =
        Stage.Oru.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

      assert Cairn.Tracker.Stage in behaviours
    end
  end
end
