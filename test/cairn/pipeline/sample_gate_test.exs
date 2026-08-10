defmodule Cairn.Pipeline.SampleGateTest do
  use ExUnit.Case, async: true

  alias Cairn.Pipeline.SampleGate

  test "the interval is the crate's own arithmetic: integer nanoseconds" do
    # `decode::sample_interval` is `1_000_000_000 / fps` in integer nanos; a
    # second spelling of this interval would be a second sample rate.
    assert SampleGate.new(5).interval_ns == 200_000_000
    assert SampleGate.new(30).interval_ns == 33_333_333
    assert SampleGate.new(1).interval_ns == 1_000_000_000
  end

  test "only the flag's own range constructs" do
    for bad <- [0, 31, -5] do
      assert_raise FunctionClauseError, fn -> SampleGate.new(bad) end
    end
  end

  test "the first frame is always admitted" do
    assert SampleGate.open?(SampleGate.new(1), System.monotonic_time(:nanosecond))
    # …wherever the monotonic clock happens to sit, including negative
    assert SampleGate.open?(SampleGate.new(1), -999_999_999_999)
  end

  test "a spent interval closes the gate until it elapses" do
    gate = SampleGate.new(5)
    now = System.monotonic_time(:nanosecond)

    gate = SampleGate.spend(gate, now)
    refute SampleGate.open?(gate, now)
    refute SampleGate.open?(gate, now + gate.interval_ns - 1)
    assert SampleGate.open?(gate, now + gate.interval_ns)
  end

  test "a burst delivered at one instant admits one frame, not several" do
    # The wall clock is the point: a stalled feed catching up must not
    # multiply model passes.
    gate = SampleGate.new(5)
    now = System.monotonic_time(:nanosecond)

    assert SampleGate.open?(gate, now)
    gate = SampleGate.spend(gate, now)

    admitted = for _ <- 1..10, SampleGate.open?(gate, now), do: :admitted
    assert admitted == []
  end

  test "spending is the caller's decision, so an unspent admission stays open" do
    # `open?` alone folds nothing in: a frame the decoder never completed
    # leaves the gate exactly as it was.
    gate = SampleGate.new(5)
    now = System.monotonic_time(:nanosecond)

    assert SampleGate.open?(gate, now)
    assert SampleGate.open?(gate, now + 1)
  end
end
