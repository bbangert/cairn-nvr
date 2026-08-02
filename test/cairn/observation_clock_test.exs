defmodule Cairn.ObservationClockTest do
  use ExUnit.Case, async: true

  alias Cairn.Observation
  alias Cairn.ObservationClock

  # `reset/1` is what a port calls when it respawns the plugin. The successor
  # process continues nobody's pts, so the anchor is dropped; it does not
  # continue nobody's *tracks*, so `at_ms` is not. Every host instant here is
  # passed in rather than read (`stamp/3` takes `now_ms`), so a jump to the host
  # clock is visible as an exact value and not as a duration that might be
  # small on a fast machine.
  describe "a plugin respawn" do
    @epoch "epoch_one"

    defp stamp(clock, media_ms, now_ms, epoch \\ @epoch) do
      ObservationClock.stamp(clock, %Observation{epoch: epoch, media_ms: media_ms}, now_ms)
    end

    test "the first observation after a reset continues from the carried at_ms" do
      {first, clock} = stamp(ObservationClock.new(), 5_000.0, 1_000)
      assert first.at_ms == 1_000

      # a stall while the plugin dies and comes back: host time has run on, and
      # the successor's pts starts wherever its own ffmpeg starts it
      clock = ObservationClock.reset(clock)
      {resumed, clock} = stamp(clock, 0.0, 90_000)

      # one floor step past where tracking time was, not the 89 seconds of host
      # clock that passed — which every live track's unseen bound would have
      # aged by at once
      assert resumed.at_ms == 1_001

      # and from there it advances at media rate again, still clamped by the host
      {next, _clock} = stamp(clock, 40.0, 90_000)
      assert next.at_ms == 1_041
    end

    test "a reset clock receiving a new epoch anchors at the host clock" do
      {_first, clock} = stamp(ObservationClock.new(), 5_000.0, 1_000)

      # the respawn came with a new ffmpeg run, so the far side of it is a gap
      # nothing observed — the suspension and adoption windows are elapsed times
      # on this clock and have to age by it
      clock = ObservationClock.reset(clock)
      {resumed, _clock} = stamp(clock, 0.0, 90_000, "epoch_two")

      assert resumed.at_ms == 90_000
    end

    test "a reset before any observation stamps like a fresh clock" do
      clock = ObservationClock.reset(ObservationClock.new())
      {first, _clock} = stamp(clock, 5_000.0, 1_000)

      assert first.at_ms == 1_000
    end
  end
end
