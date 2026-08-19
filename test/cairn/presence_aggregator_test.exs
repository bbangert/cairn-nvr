defmodule Cairn.PresenceAggregatorTest do
  use ExUnit.Case, async: true

  alias Cairn.{Event, PresenceAggregator, PresenceEvent, Registry}

  # A base far enough from 0 that `at_ms - window` never goes negative, and
  # distinct per test via the camera id so async tests can't cross-confirm
  # each other's aggregators through a shared clock.
  @base 1_000_000

  setup do
    camera_id = "pres_#{System.unique_integer([:positive])}"
    Event.subscribe()

    # A confirm here would otherwise open a real recording:
    # `Cairn.PresenceRecorder` starts beside every aggregator, and a camera
    # the config does not name has no `record:` block to refuse anything.
    # This suite is about the transitions, not the lane they drive.
    Cairn.CameraControl.set(camera_id, %{recording_enabled: false})

    # Aggregators live in the application-wide pool; without this every
    # test leaks a timer-bearing control subscriber for the suite's life.
    on_exit(fn ->
      PresenceAggregator.retire(camera_id)
      Registry.await_unregistered(camera_id, :presence)
      Registry.await_unregistered(camera_id, :presence_recorder)
    end)

    %{camera_id: camera_id}
  end

  test "a single sighting alone broadcasts nothing", %{camera_id: id} do
    PresenceAggregator.observed(id, @base, %{"person" => 0.7})
    refute_receive {:presence_started, %PresenceEvent{camera_id: ^id}}, 50
  end

  test "a second sighting inside the confirm window confirms with the max of the two scores", %{
    camera_id: id
  } do
    PresenceAggregator.observed(id, @base, %{"person" => 0.6})
    PresenceAggregator.observed(id, @base + 500, %{"person" => 0.9})

    assert_receive {:presence_started,
                    %PresenceEvent{camera_id: ^id, label: "person", score: 0.9} = event}

    assert DateTime.compare(event.first_seen_at, event.at) in [:lt, :eq]
  end

  test "a second sighting after the confirm window does not confirm; a close third does", %{
    camera_id: id
  } do
    PresenceAggregator.observed(id, @base, %{"person" => 0.6})
    # 3_000ms > the 2_000ms window: the first sighting was a lone flicker.
    PresenceAggregator.observed(id, @base + 3_000, %{"person" => 0.7})
    refute_receive {:presence_started, %PresenceEvent{camera_id: ^id}}, 50

    # Candidacy restarted at `@base + 3_000`; this one lands inside its window.
    PresenceAggregator.observed(id, @base + 3_500, %{"person" => 0.8})
    assert_receive {:presence_started, %PresenceEvent{camera_id: ^id, label: "person"}}
  end

  test "two frames of one buffer — two calls, one instant — still confirm", %{camera_id: id} do
    # A multi-frame `Detections` buffer reaches the aggregator as calls
    # sharing the sink's one clock read; they are two model passes on two
    # source frames, which is what the confirm asks for.
    PresenceAggregator.observed(id, @base, %{"person" => 0.6})
    PresenceAggregator.observed(id, @base, %{"person" => 0.7})

    assert_receive {:presence_started, %PresenceEvent{camera_id: ^id, label: "person"}}
  end

  test "a second sighting exactly at the window's edge confirms — the bound is inclusive", %{
    camera_id: id
  } do
    PresenceAggregator.observed(id, @base, %{"person" => 0.6})
    PresenceAggregator.observed(id, @base + 2_000, %{"person" => 0.7})

    assert_receive {:presence_started, %PresenceEvent{camera_id: ^id, label: "person"}}
  end

  test "a later, better sighting raises the score the clearing reports", %{camera_id: id} do
    PresenceAggregator.observed(id, @base, %{"person" => 0.6})
    PresenceAggregator.observed(id, @base + 500, %{"person" => 0.7})
    assert_receive {:presence_started, %PresenceEvent{camera_id: ^id, score: 0.7}}

    PresenceAggregator.observed(id, @base + 1_000, %{"person" => 0.95})
    PresenceAggregator.observed(id, @base + 6_000, %{})
    PresenceAggregator.observed(id, @base + 11_000, %{})

    assert_receive {:presence_cleared, %PresenceEvent{camera_id: ^id, score: 0.95}}
  end

  test "present labels do not clear on absent batches inside the clear window, but every absent batch (even empty) still counts toward it",
       %{camera_id: id} do
    PresenceAggregator.observed(id, @base, %{"person" => 0.6})
    PresenceAggregator.observed(id, @base + 500, %{"person" => 0.9})
    assert_receive {:presence_started, %PresenceEvent{camera_id: ^id, label: "person"}}

    # The span opens at the FIRST absent batch — an empty map is still
    # evidence (frames flowed, nothing qualified) — and one absent batch
    # alone never clears.
    PresenceAggregator.observed(id, @base + 1_000, %{})
    refute_receive {:presence_cleared, %PresenceEvent{camera_id: ^id}}, 50

    # 4_500ms of absence span: still under the 5_000ms window.
    PresenceAggregator.observed(id, @base + 5_500, %{})
    refute_receive {:presence_cleared, %PresenceEvent{camera_id: ^id}}, 50

    # 5_000ms absent-to-absent: clears, carrying the best score.
    PresenceAggregator.observed(id, @base + 6_000, %{})

    assert_receive {:presence_cleared,
                    %PresenceEvent{camera_id: ^id, label: "person", score: 0.9}}
  end

  test "silence before the first absent batch counts for nothing — the span is evidence, not elapsed time",
       %{camera_id: id} do
    PresenceAggregator.observed(id, @base, %{"person" => 0.6})
    PresenceAggregator.observed(id, @base + 500, %{"person" => 0.9})
    assert_receive {:presence_started, %PresenceEvent{camera_id: ^id, label: "person"}}

    # Ten minutes of gate-closed silence, then the scene wakes without the
    # person: the elapsed time must not let this single batch clear.
    PresenceAggregator.observed(id, @base + 600_000, %{})
    refute_receive {:presence_cleared, %PresenceEvent{camera_id: ^id}}, 50

    # The second absent observation closes a real 5_000ms evidence span.
    PresenceAggregator.observed(id, @base + 605_000, %{})
    assert_receive {:presence_cleared, %PresenceEvent{camera_id: ^id, label: "person"}}
  end

  test "a pending label that never confirmed goes stale without ever broadcasting", %{
    camera_id: id
  } do
    PresenceAggregator.observed(id, @base, %{"person" => 0.5})
    # A full absence span elapses, but the label never reached :present —
    # `absences/4` drops it silently.
    PresenceAggregator.observed(id, @base + 1_000, %{})
    PresenceAggregator.observed(id, @base + 6_000, %{})

    refute_receive {:presence_started, %PresenceEvent{camera_id: ^id}}, 50
    refute_receive {:presence_cleared, %PresenceEvent{camera_id: ^id}}, 50
  end

  test "detection_disabled/1 clears every present label at once, and is a no-op with nothing running",
       %{camera_id: id} do
    PresenceAggregator.observed(id, @base, %{"person" => 0.6, "car" => 0.5})
    PresenceAggregator.observed(id, @base + 500, %{"person" => 0.6, "car" => 0.5})
    assert_receive {:presence_started, %PresenceEvent{camera_id: ^id, label: "person"}}
    assert_receive {:presence_started, %PresenceEvent{camera_id: ^id, label: "car"}}

    PresenceAggregator.detection_disabled(id)

    labels =
      for _ <- 1..2 do
        assert_receive {:presence_cleared, %PresenceEvent{camera_id: ^id, label: label}}
        label
      end

    assert Enum.sort(labels) == ["car", "person"]

    # No-op: nothing registered for a camera that never called `observed/3`.
    other_id = "pres_#{System.unique_integer([:positive])}"
    assert PresenceAggregator.detection_disabled(other_id) == :ok
    assert Registry.whereis(other_id, :presence) == nil
    refute_receive {:presence_cleared, %PresenceEvent{camera_id: ^other_id}}, 50
  end

  test "a detection-disable broadcast clears with the gate closed — no batch needed", %{
    camera_id: id
  } do
    PresenceAggregator.observed(id, @base, %{"person" => 0.6})
    PresenceAggregator.observed(id, @base + 500, %{"person" => 0.9})
    assert_receive {:presence_started, %PresenceEvent{camera_id: ^id, label: "person"}}

    # The out-of-band path: no buffer arrives (still scene, closed gate) —
    # the aggregator hears the control broadcast itself.
    Cairn.CameraControl.set(id, %{detection_enabled: false})
    on_exit(fn -> Cairn.CameraControl.set(id, %{detection_enabled: true}) end)

    assert_receive {:presence_cleared, %PresenceEvent{camera_id: ^id, label: "person"}}
  end

  test "an observed batch in flight past a disable is dropped at consume time", %{camera_id: id} do
    # The race the sink cannot close: its control read happens a message
    # before the disable broadcast; the aggregator's own read at consume
    # time is the authoritative one.
    Cairn.CameraControl.set(id, %{detection_enabled: false})
    on_exit(fn -> Cairn.CameraControl.set(id, %{detection_enabled: true}) end)

    PresenceAggregator.observed(id, @base, %{"person" => 0.9})
    PresenceAggregator.observed(id, @base + 500, %{"person" => 0.9})

    refute_receive {:presence_started, %PresenceEvent{camera_id: ^id}}, 50
  end

  test "a crash's unanswered presence_started gets its cleared from the restart", %{
    camera_id: id
  } do
    PresenceAggregator.observed(id, @base, %{"person" => 0.6})
    PresenceAggregator.observed(id, @base + 500, %{"person" => 0.9})
    assert_receive {:presence_started, %PresenceEvent{camera_id: ^id, label: "person"}}

    # An abnormal exit: `:transient` restarts it, and the fresh init owes
    # the world the cleared its predecessor never sent (the
    # every-started-gets-a-cleared invariant, via the ledger).
    pid = Registry.whereis(id, :presence)
    Process.exit(pid, :kill)

    assert_receive {:presence_cleared,
                    %PresenceEvent{camera_id: ^id, label: "person", score: 0.9}}
  end

  test "heartbeats keep the silence backstop from clearing a gated-but-live stream", %{
    camera_id: id
  } do
    base = System.monotonic_time(:millisecond) - 700_000

    PresenceAggregator.observed(id, base, %{"person" => 0.6})
    PresenceAggregator.observed(id, base + 500, %{"person" => 0.9})
    assert_receive {:presence_started, %PresenceEvent{camera_id: ^id, label: "person"}}

    # The native gate has been skipping for 700s — but the sink's
    # heartbeats say the stream is alive, so the backstop must hold.
    PresenceAggregator.heartbeat(id, System.monotonic_time(:millisecond))
    pid = Registry.whereis(id, :presence)
    send(pid, :silence_check)

    refute_receive {:presence_cleared, %PresenceEvent{camera_id: ^id}}, 50
  end

  test "retire/1 clears, stops, and stays gone until the next batch", %{camera_id: id} do
    PresenceAggregator.observed(id, @base, %{"person" => 0.6})
    PresenceAggregator.observed(id, @base + 500, %{"person" => 0.9})
    assert_receive {:presence_started, %PresenceEvent{camera_id: ^id, label: "person"}}

    pid = Registry.whereis(id, :presence)
    ref = Process.monitor(pid)
    PresenceAggregator.retire(id)

    assert_receive {:presence_cleared, %PresenceEvent{camera_id: ^id, label: "person"}}
    # A normal stop: `:transient` must not restart it, and the registry
    # entry dies with the process — awaited, since the registry's own DOWN
    # handling races the test's monitor.
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    Registry.await_unregistered(id, :presence)
    assert Registry.whereis(id, :presence) == nil

    # Retiring a camera that has no aggregator is the common (tracked) case.
    assert PresenceAggregator.retire("no_such_#{System.unique_integer([:positive])}") == :ok
  end

  test "silence alone (no batches at all) never clears presence", %{camera_id: id} do
    PresenceAggregator.observed(id, @base, %{"person" => 0.6})
    PresenceAggregator.observed(id, @base + 500, %{"person" => 0.9})
    assert_receive {:presence_started, %PresenceEvent{camera_id: ^id, label: "person"}}

    # No further batches ever arrive — a closed motion gate, not a dead
    # stream. Clearing only advances on batches that arrive without the
    # label, per the moduledoc's gate-aware rule.
    refute_receive {:presence_cleared, %PresenceEvent{camera_id: ^id}}, 100
  end

  test "the silence backstop clears presence long after the last batch, via :silence_check", %{
    camera_id: id
  } do
    # Old enough (~700s) that the real monotonic clock has already crossed
    # the 600_000ms backstop by the time `:silence_check` is handled.
    base = System.monotonic_time(:millisecond) - 700_000

    PresenceAggregator.observed(id, base, %{"person" => 0.6})
    PresenceAggregator.observed(id, base + 500, %{"person" => 0.9})
    assert_receive {:presence_started, %PresenceEvent{camera_id: ^id, label: "person"}}

    pid = Registry.whereis(id, :presence)
    send(pid, :silence_check)

    assert_receive {:presence_cleared, %PresenceEvent{camera_id: ^id, label: "person"}}

    # One-shot: the clear also drops the batch history, so the next check has
    # nothing left to age (would otherwise re-run an empty clear per minute).
    assert :sys.get_state(pid).last_batch_ms == nil
  end
end
