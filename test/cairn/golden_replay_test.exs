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
    for name <- ~w(adoption_across_cut cap_eviction epoch_change) do
      test "#{name} replays to its golden" do
        first = GoldenReplay.replay_steps(unquote(name))
        second = GoldenReplay.replay_steps(unquote(name))

        assert first == second, "steps #{unquote(name)}: replay is nondeterministic"
        GoldenReplay.check_golden(unquote(name), first)
      end
    end
  end

  describe "golden bookkeeping" do
    test "a missing golden names the regen task instead of diffing nothing" do
      # Under `mix cairn.golden.regen` this call would *create* the file, so
      # the assertion only holds in comparison mode; regen runs skip it.
      unless System.get_env("GOLDEN_REGEN") do
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
