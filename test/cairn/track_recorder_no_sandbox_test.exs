defmodule Cairn.TrackRecorderNoSandboxTest do
  # Deliberately NOT `Cairn.DataCase`: with no sandbox connection checked out,
  # every Repo call made from this module's processes raises
  # `DBConnection.OwnershipError` — the suite's stand-in for "the database is
  # not answering", which is what makes both facts here observable:
  #
  #   * an empty flush is a no-op that never reaches the Repo (nothing is
  #     logged), and
  #   * a non-empty flush that the Repo refuses drops its batch and leaves the
  #     recorder alive.
  #
  # The first is not a test-only nicety: the recorder wakes on its timer
  # forever on an idle host, and "the flush path is not entered at all with an
  # empty buffer" is the property that keeps those wakeups free — two modules
  # deep, `Cairn.Tracks.insert_batch/1` also short-circuits an empty list, so
  # this pins the behaviour rather than either implementation.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias Cairn.{Track, TrackRecorder, Tracks}

  setup do
    await_unowned_repo()
    :ok
  end

  test "an empty flush makes no Repo call at all" do
    rec = start_supervised!({TrackRecorder, name: nil, manual: true})

    log = capture_log(fn -> flush(rec) end)

    assert Process.alive?(rec)
    refute log =~ "dropped a batch"
  end

  test "a refused batch is dropped, warned about once, and the recorder lives" do
    rec = start_supervised!({TrackRecorder, name: nil, manual: true})

    log =
      capture_log(fn ->
        TrackRecorder.record_final(rec, final(), nil)
        TrackRecorder.record_final(rec, final(), nil)
        flush(rec)
      end)

    assert Process.alive?(rec)
    assert log =~ "dropped a batch of 2 tracks"
  end

  defp flush(rec) do
    send(rec, {:flush, :sys.get_state(rec).flush_token})
    _ = :sys.get_state(rec)
    :ok
  end

  defp final do
    %Track{
      object_id: Cairn.ULID.generate(),
      camera_id: "trec_nosandbox",
      label: "person",
      score: 0.8,
      best_score: 0.9,
      bbox: [0, 0, 1, 1],
      source: :host,
      started_at: DateTime.utc_now(),
      last_seen_at: DateTime.utc_now(),
      end_reason: :unseen
    }
  end

  # This module can inherit the tail of a previous one's sandbox teardown,
  # where a Repo call *exits* ("owner exited") rather than raising. Only the
  # raise is stable — once the owner is reaped every call raises, and no owner
  # can appear afterwards because this module never checks one out. Failing
  # loudly when the Repo turns out to be reachable is what stops both tests
  # above from passing vacuously against a working database.
  defp await_unowned_repo(attempts \\ 100) do
    case probe_repo() do
      {:raised, %DBConnection.OwnershipError{}} ->
        :ok

      _other when attempts > 0 ->
        Process.sleep(10)
        await_unowned_repo(attempts - 1)

      other ->
        flunk("the track index is still reachable from this test: #{inspect(other)}")
    end
  end

  defp probe_repo do
    {:ok, Tracks.get(Cairn.ULID.generate())}
  rescue
    e -> {:raised, e}
  catch
    :exit, reason -> {:exited, reason}
  end
end
