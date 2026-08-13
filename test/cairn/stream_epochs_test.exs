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
    assert_receive {:stream_epoch, ^id, :main, ^epoch, :started}
    assert StreamEpochs.current(id) == {:ok, epoch}

    next = StreamEpochs.new_epoch(id, :source_lost)
    assert_receive {:stream_epoch, ^id, :main, ^next, :source_lost}
    assert next != epoch
    assert StreamEpochs.current(id) == {:ok, next}
  end

  test "the returned epoch is the stored epoch is the broadcast epoch", %{id: id} do
    StreamEpochs.subscribe()

    returned = StreamEpochs.new_epoch(id, :started)

    assert_receive {:stream_epoch, ^id, :main, broadcast, :started}
    assert {:ok, stored} = StreamEpochs.current(id)

    # single source of truth: the caller mints, so no path can hand the caller
    # one epoch while ETS and subscribers learn about another
    assert returned == broadcast
    assert returned == stored
  end

  test "a late-served request stores the caller's epoch, not a fresh one", %{id: id} do
    epoch = StreamEpochs.new_epoch(id, :started)

    # what a call that exited with :timeout leaves behind: the request is still
    # queued and gets served afterwards. It carries the epoch the caller
    # already returned, so replaying it must be a no-op on `current/1`.
    GenServer.call(StreamEpochs, {:new_epoch, {id, :main}, epoch, :started})

    assert StreamEpochs.current(id) == {:ok, epoch}
  end

  test "an out-of-order mint from an earlier millisecond is neither stored nor announced", %{
    id: id
  } do
    StreamEpochs.subscribe()

    current = StreamEpochs.new_epoch(id, :started)
    assert_receive {:stream_epoch, ^id, :main, ^current, :started}

    # two calls minted close together can be served out of order; the older one
    # would otherwise roll `current/1` back to a stream nothing decodes under,
    # while consumers that already applied the newer one stay on it — every
    # observation dropped as stale until the camera's next mint
    stale = Cairn.ULID.generate(1)
    GenServer.call(StreamEpochs, {:new_epoch, {id, :main}, stale, :source_lost})

    assert StreamEpochs.current(id) == {:ok, current}
    refute_receive {:stream_epoch, ^id, :main, ^stale, _reason}, 100
  end

  test "epochs are per camera", %{id: id} do
    other = "ep_#{System.unique_integer([:positive])}"

    epoch = StreamEpochs.new_epoch(id, :started)
    other_epoch = StreamEpochs.new_epoch(other, :started)

    assert StreamEpochs.current(id) == {:ok, epoch}
    assert StreamEpochs.current(other) == {:ok, other_epoch}
  end

  test "a bare camera id is the :main stream", %{id: id} do
    epoch = StreamEpochs.new_epoch({id, :main}, :started)

    assert StreamEpochs.current(id) == {:ok, epoch}
    assert StreamEpochs.new_epoch(id, :source_lost) == elem(StreamEpochs.current({id, :main}), 1)
  end

  test "the two roles of one camera are independent", %{id: id} do
    StreamEpochs.subscribe()

    main = StreamEpochs.new_epoch({id, :main}, :started)
    assert_receive {:stream_epoch, ^id, :main, ^main, :started}

    sub = StreamEpochs.new_epoch({id, :sub}, :started)
    assert_receive {:stream_epoch, ^id, :sub, ^sub, :started}

    # the sub's own reconnect leaves main exactly where it was: two ingests,
    # two session lifetimes, and no consumer of one may be moved by the other
    sub_again = StreamEpochs.new_epoch({id, :sub}, :source_lost)
    assert_receive {:stream_epoch, ^id, :sub, ^sub_again, :source_lost}

    assert StreamEpochs.current({id, :main}) == {:ok, main}
    assert StreamEpochs.current({id, :sub}) == {:ok, sub_again}
  end

  test "an older main epoch does not supersede a newer sub one", %{id: id} do
    # ULIDs are globally time-ordered, so a shared supersession check would
    # retire the sub's fresh mint whenever main had reconnected more recently
    sub = StreamEpochs.new_epoch({id, :sub}, :started)
    main = StreamEpochs.new_epoch({id, :main}, :started)

    GenServer.call(StreamEpochs, {:new_epoch, {id, :sub}, Cairn.ULID.generate(1), :source_lost})

    assert StreamEpochs.current({id, :sub}) == {:ok, sub}
    assert StreamEpochs.current({id, :main}) == {:ok, main}
  end

  test "role_of names the stream an epoch is current on", %{id: id} do
    main = StreamEpochs.new_epoch({id, :main}, :started)
    sub = StreamEpochs.new_epoch({id, :sub}, :started)

    assert StreamEpochs.role_of(id, main) == {:ok, :main}
    assert StreamEpochs.role_of(id, sub) == {:ok, :sub}
    assert StreamEpochs.role_of(id, Cairn.ULID.generate()) == :unknown

    # superseded is the same answer as never-seen: it names no running stream
    StreamEpochs.new_epoch({id, :sub}, :source_lost)
    assert StreamEpochs.role_of(id, sub) == :unknown
  end

  test "the table dies with the owner and the next spawn re-mints", %{id: id} do
    before = StreamEpochs.new_epoch(id, :started)

    pid = Process.whereis(StreamEpochs)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    # Accepted behaviour, deliberately not fought: the ETS table is owned by
    # the GenServer, so a crash loses every epoch. Readers see :unknown until
    # the camera's next spawn re-mints — and a *changed* epoch cuts the tracker
    # element's live set at the next batch, which is the conservative outcome.
    assert StreamEpochs.current(id) == :unknown

    restarted = wait_for_restart(pid)
    assert restarted != pid

    epoch = StreamEpochs.new_epoch(id, :started)
    # the re-mint must be a *new* epoch: an implementation that survived the
    # crash with the same one (heir, :public table, DETS) would defeat the
    # "a re-mint is a change, which ends tracks" argument above
    assert epoch != before
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
