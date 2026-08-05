defmodule Cairn.GoldenReplayTest do
  @moduledoc """
  Golden replay regression suite — see `Cairn.GoldenReplay` and
  `test/support/golden/README.md`.

  Runs in the default `mix test` (fast, hermetic: no ffmpeg, no cargo, no
  clips). Every replay test renders twice and asserts the two renderings
  identical before comparing against the golden, so a nondeterminism bug in
  the harness itself — the silent failure mode that would mask real
  divergence — surfaces here rather than as a flaky golden.
  """

  use ExUnit.Case, async: true

  alias Cairn.GoldenReplay

  @moduletag :golden
  # `warn_once/4` fires on the cap-eviction fixture by design; the harness
  # reads events, never logs.
  @moduletag capture_log: true

  describe "capture replays" do
    for name <- ~w(active still) do
      test "#{name} replays to its golden" do
        first = GoldenReplay.replay_capture(unquote(name))
        second = GoldenReplay.replay_capture(unquote(name))

        assert first == second, "capture #{unquote(name)}: replay is nondeterministic"
        GoldenReplay.check_golden(unquote(name), first)
      end
    end
  end

  describe "step-script replays" do
    for name <- ~w(adoption_across_cut cap_eviction epoch_change twin_mint_off) do
      test "#{name} replays to its golden" do
        first = GoldenReplay.replay_steps(unquote(name))
        second = GoldenReplay.replay_steps(unquote(name))

        assert first == second, "steps #{unquote(name)}: replay is nondeterministic"
        GoldenReplay.check_golden(unquote(name), first)
      end
    end
  end

  describe "profiled-policy equivalence" do
    test "a stage presence map replays byte-identically to the boolean flags" do
      # The soak policy's flags, expressed the way a profiled camera's policy
      # carries them (`Cairn.Config.policy/2`'s `stages` map). If the two
      # forms ever produce different context stage lists, this diverges from
      # the committed golden the boolean run is checked against — proving
      # stage-list path ≡ boolean path on the same fixture, per D-P7.
      profiled = %{
        max_unseen_ms: 3_000,
        max_live_tracks: 128,
        stationary_after_ms: 10_000,
        min_score: %{"default" => 0.5},
        stages: %{bbd: %{}, oru: %{}, twin_mint: %{}}
      }

      assert GoldenReplay.replay_capture("active", profiled) ==
               GoldenReplay.replay_capture("active")
    end

    test "a partial presence map equals its boolean spelling too" do
      # bbd listed alone: oru and twin_mint delisted by absence. The boolean
      # spelling of the same choice needs twin_mint written out, since its
      # boolean default is on — which is exactly the asymmetry this pins.
      partial = %{
        max_unseen_ms: 3_000,
        max_live_tracks: 128,
        stationary_after_ms: 10_000,
        min_score: %{"default" => 0.5},
        stages: %{bbd: %{}}
      }

      booleans = %{
        max_unseen_ms: 3_000,
        max_live_tracks: 128,
        stationary_after_ms: 10_000,
        min_score: %{"default" => 0.5},
        bbd: true,
        oru: false,
        twin_mint: false
      }

      assert GoldenReplay.replay_capture("active", partial) ==
               GoldenReplay.replay_capture("active", booleans)
    end
  end

  describe "golden bookkeeping" do
    test "a missing golden names the regen task instead of diffing nothing" do
      # Under `mix cairn.golden.regen` this call would *create* the file, so
      # the assertion only holds in comparison mode; regen runs skip it.
      unless System.get_env("GOLDEN_REGEN") == "1" do
        assert_raise RuntimeError, ~r/missing golden .*cairn\.golden\.regen/, fn ->
          GoldenReplay.check_golden("no_such_fixture", "x\n")
        end
      end
    end

    test "every rendered object id is a mint ordinal, never a raw ULID" do
      # The strict-translation guarantee, asserted from the outside: parse a
      # rendering and check each object_id in events, tags and the checkpoint.
      # (The raise inside `canon_id/2` itself is unreachable through the
      # public drivers — a fresh tracker mints every id through `:started` —
      # so this asserts the property, not the defensive branch.)
      ids =
        "adoption_across_cut"
        |> GoldenReplay.replay_steps()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)
        |> Enum.flat_map(fn
          %{"checkpoint" => tracks} ->
            Enum.map(tracks, & &1["object_id"])

          %{"state_hash" => _hash} ->
            []

          batch ->
            Enum.map(batch["events"] || [], & &1["track"]["object_id"]) ++
              Enum.map(batch["tagged"] || [], & &1["object_id"])
        end)

      assert ids != [], "fixture rendered no object ids at all"
      assert Enum.all?(ids, &(&1 =~ ~r/^T\d{4}$/)), "raw id leaked: #{inspect(ids)}"
    end
  end
end
