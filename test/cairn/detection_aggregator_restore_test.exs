defmodule Cairn.DetectionAggregatorRestoreTest do
  # Deliberately NOT `Cairn.DataCase`: with no sandbox connection checked out,
  # every Repo call made from this module raises `DBConnection.OwnershipError`.
  # That is the suite's faithful stand-in for "the database is not answering",
  # which is the condition checkpoint restore has to survive — it runs inside
  # `init/1` of a singleton that serves every camera.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias Cairn.{DataCase, DetectionAggregator, Event, EventCheckpoint, Events}

  setup do
    DataCase.reset_checkpoints()
    Event.subscribe()
    :ok
  end

  test "restore survives an unreachable event index and still ends the orphan" do
    await_unreachable_index()

    camera_id = "aggr_#{System.unique_integer([:positive])}"

    event = %Event{
      id: Ecto.UUID.generate(),
      camera_id: camera_id,
      started_at: DateTime.utc_now()
    }

    EventCheckpoint.put(camera_id, event)
    eid = event.id

    log =
      capture_log(fn ->
        agg = start_supervised!({DetectionAggregator, name: nil}, id: :agg_restore_no_index)

        assert Process.alive?(agg)
        assert_receive {:event_ended, %Event{id: ^eid, status: :partial}}
        assert EventCheckpoint.all() |> Enum.filter(&(elem(&1, 0) == camera_id)) == []
      end)

    assert log =~ "could not consult the event index"
  end

  # This module inherits the tail of the previous one's sandbox teardown: while
  # a shared owner is exiting, a Repo call *exits* with "owner exited" rather
  # than raising `DBConnection.OwnershipError`. Both are "the index is not
  # answering", but only the second is stable — once the ownership manager has
  # reaped the owner every call raises, and no owner can appear afterwards
  # because this module never checks one out. Waiting for that state, and
  # failing loudly if the index turns out to be reachable, is what stops the
  # test from passing vacuously against a working index.
  defp await_unreachable_index(attempts \\ 100) do
    case probe_index() do
      {:raised, %DBConnection.OwnershipError{}} ->
        :ok

      _other when attempts > 0 ->
        Process.sleep(10)
        await_unreachable_index(attempts - 1)

      other ->
        flunk("the event index is still reachable from this test: #{inspect(other)}")
    end
  end

  defp probe_index do
    {:ok, Events.get(Ecto.UUID.generate())}
  rescue
    e -> {:raised, e}
  catch
    :exit, reason -> {:exited, reason}
  end
end
