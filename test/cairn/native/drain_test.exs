defmodule Cairn.Native.DrainTest do
  use ExUnit.Case, async: false

  alias Cairn.Native.Drain

  @moduletag :capture_log

  test "a supervisor shutdown runs the drains rather than skipping terminate" do
    # Trapping exits is Drain's whole mechanism: without it, this stop kills
    # the process before terminate/2 — and the drains — ever run. On this box
    # both NIF libraries are the real ones, so the calls exercise the real
    # drain path against an idle queue and must come back immediately. The
    # notify seam is what makes this a test of the drains and not merely of
    # the exit reason — a no-op terminate would still deliver :shutdown.
    pid =
      start_supervised!(
        {Drain, name: :"drain_#{System.unique_integer([:positive])}", notify: self()}
      )

    ref = Process.monitor(pid)

    :ok = stop_supervised!(Drain)

    assert_receive {:drained, CairnOrt, true}
    assert_receive {:drained, Cairn.Native, true}
    assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}
  end

  test "the child spec outlasts terminate's worst case by construction" do
    # The default worker shutdown (5000 ms) is SHORTER than two sequential
    # 5000 ms drains: a bare child spec gets killed mid-drain, silently
    # skipping the second library. The spec must say so explicitly.
    assert %{shutdown: shutdown} = Drain.child_spec([])
    assert shutdown > 2 * 5_000
  end

  test "an idle native queue drains immediately on both libraries" do
    # The exit path's happy case, called the way Drain.terminate/2 calls it.
    # Guarded on availability so a CI image without the .so files skips the
    # NIF rather than raising nif_not_loaded.
    if Cairn.Native.available?(), do: assert(Cairn.Native.drain_teardown(5_000))
    if CairnOrt.available?(), do: assert(CairnOrt.drain_teardown(5_000))
  end
end
