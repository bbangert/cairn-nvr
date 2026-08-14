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

  test "present labels do not clear on absent batches inside the clear window, but every absent batch (even empty) still counts toward it",
       %{camera_id: id} do
    PresenceAggregator.observed(id, @base, %{"person" => 0.6})
    PresenceAggregator.observed(id, @base + 500, %{"person" => 0.9})
    assert_receive {:presence_started, %PresenceEvent{camera_id: ^id, label: "person"}}

    # 4_000ms since the confirming sighting: under the 5_000ms clear window.
    # An empty map is still evidence — frames flowed, nothing qualified.
    PresenceAggregator.observed(id, @base + 500 + 4_000, %{})
    refute_receive {:presence_cleared, %PresenceEvent{camera_id: ^id}}, 50

    # 5_000ms since the confirming sighting: clears, carrying the best score.
    PresenceAggregator.observed(id, @base + 500 + 5_000, %{})

    assert_receive {:presence_cleared,
                    %PresenceEvent{camera_id: ^id, label: "person", score: 0.9}}
  end

  test "a pending label that never confirmed goes stale without ever broadcasting", %{
    camera_id: id
  } do
    PresenceAggregator.observed(id, @base, %{"person" => 0.5})
    # Past the 5_000ms clear window, but the label never reached :present —
    # `absences/4` drops it silently.
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
  end
end
