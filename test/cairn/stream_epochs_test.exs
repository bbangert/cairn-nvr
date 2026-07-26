defmodule Cairn.StreamEpochsTest do
  # kills the application-wide GenServer, so it must not overlap other tests
  use ExUnit.Case, async: false

  alias Cairn.StreamEpochs

  setup do
    %{id: "ep_#{System.unique_integer([:positive])}"}
  end

  test "a camera that never spawned has no epoch", %{id: id} do
    assert StreamEpochs.current(id) == :unknown
  end

  test "new_epoch mints, stores and broadcasts", %{id: id} do
    StreamEpochs.subscribe()

    epoch = StreamEpochs.new_epoch(id, :started)
    assert_receive {:stream_epoch, ^id, ^epoch, :started}
    assert StreamEpochs.current(id) == {:ok, epoch}

    next = StreamEpochs.new_epoch(id, :source_lost)
    assert_receive {:stream_epoch, ^id, ^next, :source_lost}
    assert next != epoch
    assert StreamEpochs.current(id) == {:ok, next}
  end

  test "epochs are per camera", %{id: id} do
    other = "ep_#{System.unique_integer([:positive])}"

    epoch = StreamEpochs.new_epoch(id, :started)
    other_epoch = StreamEpochs.new_epoch(other, :started)

    assert StreamEpochs.current(id) == {:ok, epoch}
    assert StreamEpochs.current(other) == {:ok, other_epoch}
  end

  test "the table dies with the owner and the next spawn re-mints", %{id: id} do
    StreamEpochs.new_epoch(id, :started)

    pid = Process.whereis(StreamEpochs)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    # Accepted behaviour, deliberately not fought: the ETS table is owned by
    # the GenServer, so a crash loses every epoch. Readers see :unknown until
    # the camera's next spawn re-mints — and a *changed* epoch ends tracks in
    # Cairn.DetectionAggregator, which is the conservative outcome.
    assert StreamEpochs.current(id) == :unknown

    restarted = wait_for_restart(pid)
    assert restarted != pid

    epoch = StreamEpochs.new_epoch(id, :started)
    assert StreamEpochs.current(id) == {:ok, epoch}
  end

  defp wait_for_restart(old_pid, attempts \\ 200) do
    case Process.whereis(StreamEpochs) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _ when attempts == 0 ->
        flunk("Cairn.StreamEpochs was never restarted")

      _ ->
        Process.sleep(10)
        wait_for_restart(old_pid, attempts - 1)
    end
  end
end
