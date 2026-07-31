defmodule Cairn.TracksTest do
  # async: false — these write through the real pool (the cascade test rides on
  # the connection's own `PRAGMA foreign_keys`), and `Cairn.DataCase` notes that
  # async sandboxing is not recommended outside PostgreSQL.
  use Cairn.DataCase, async: false

  alias Cairn.Tracks
  alias Cairn.Tracks.TrackEvent

  defp track_attrs(overrides \\ %{}) do
    started = DateTime.utc_now()

    Map.merge(
      %{
        id: Cairn.ULID.generate(),
        camera_id: "cam_a",
        started_at: started,
        ended_at: DateTime.add(started, 30),
        label: "person",
        best_score: 0.91,
        source: :host,
        epoch: "epoch-1",
        end_reason: :unseen
      },
      overrides
    )
  end

  defp moment(kind, at, bbox \\ [10, 20.5, 30, 40]) do
    %{at: at, kind: kind, bbox: bbox}
  end

  defp seed(overrides, moments \\ []) do
    attrs = track_attrs(overrides)
    {:ok, _counts} = Tracks.insert_batch([{attrs, moments}])
    attrs
  end

  test "insert_batch round-trips a track and its moments" do
    started = DateTime.utc_now()
    attrs = track_attrs(%{started_at: started, stationary_ms: 4200, entry_bbox: [1, 2.5, 3, 4]})

    assert {:ok, %{tracks: 1, moments: 2}} =
             Tracks.insert_batch([
               {attrs,
                [moment(:appeared, started), moment(:became_stationary, DateTime.add(started, 5))]}
             ])

    row = Tracks.get(attrs.id)
    assert row.camera_id == "cam_a"
    assert row.label == "person"
    assert row.best_score == 0.91
    assert row.source == :host
    assert row.end_reason == :unseen
    assert row.stationary_ms == 4200
    assert row.event_id == nil
    assert row.zones == []
    # Boxes survive as the number lists they were, mixed ints and floats.
    assert row.entry_bbox == [1, 2.5, 3, 4]
    # utc_datetime_usec: microseconds survive the SQLite text round trip. The
    # precision check keeps the equality above from passing vacuously on a
    # DateTime that never carried microseconds.
    assert row.started_at == started
    assert elem(started.microsecond, 1) == 6

    assert [%TrackEvent{kind: :appeared, bbox: [10, 20.5, 30, 40], track_id: track_id}, _] =
             Tracks.moments(attrs.id)

    assert track_id == attrs.id
  end

  test "insert_batch chunks past the SQLite bind-variable ceiling" do
    # >400 moments cross the chunk boundary. The chunking exists to keep a batch
    # under SQLite's 32766 bind variables per statement; this pins that splitting
    # the batch neither loses nor duplicates rows.
    started = DateTime.utc_now()
    attrs = track_attrs()
    moments = for i <- 1..950, do: moment(:appeared, DateTime.add(started, i, :millisecond))

    assert {:ok, %{tracks: 1, moments: 950}} = Tracks.insert_batch([{attrs, moments}])
    assert length(Tracks.moments(attrs.id)) == 950
  end

  test "deleting a track takes its moments with it" do
    # Cascade proof through the real pool, not a schema reading: ecto_sqlite3
    # opens connections with `PRAGMA foreign_keys = ON` by default, and ON
    # DELETE CASCADE is a silent no-op without it. If that default ever changes
    # or a pool option overrides it, this test is what says so.
    old = DateTime.add(DateTime.utc_now(), -400 * 86_400)
    attrs = seed(%{started_at: old, ended_at: old}, [moment(:appeared, old)])

    assert Tracks.moments(attrs.id) != []
    assert Tracks.delete_ended_before(DateTime.utc_now()) == 1
    assert Tracks.get(attrs.id) == nil
    assert Tracks.moments(attrs.id) == []
  end

  test "delete_ended_before spares live tracks of any age" do
    old = DateTime.add(DateTime.utc_now(), -400 * 86_400)
    recent = DateTime.add(DateTime.utc_now(), -1 * 86_400)
    ancient_live = seed(%{started_at: old, ended_at: nil})
    ancient_ended = seed(%{started_at: old, ended_at: old})
    recent_ended = seed(%{started_at: recent, ended_at: recent})

    cutoff = DateTime.add(DateTime.utc_now(), -7 * 86_400)
    assert Tracks.delete_ended_before(cutoff) == 1

    assert Tracks.get(ancient_ended.id) == nil
    assert Tracks.get(ancient_live.id) != nil
    assert Tracks.get(recent_ended.id) != nil
  end

  test "delete_ended_before is exclusive at the cutoff instant" do
    cutoff = DateTime.add(DateTime.utc_now(), -7 * 86_400)
    at_cutoff = seed(%{started_at: cutoff, ended_at: cutoff})

    # strictly `<`: a track that ended at the cutoff instant survives this
    # sweep and falls to the next one
    assert Tracks.delete_ended_before(cutoff) == 0
    assert Tracks.get(at_cutoff.id) != nil
  end

  test "recorded: false lists exactly the tracks that never made a clip" do
    unrecorded = seed(%{label: "cat"})
    recorded = seed(%{event_id: "evt_1"})

    assert %{total: 1, tracks: [row]} = Tracks.list(recorded: false)
    assert row.id == unrecorded.id

    assert %{total: 1, tracks: [row]} = Tracks.list(recorded: true)
    assert row.id == recorded.id

    assert %{total: 2} = Tracks.list()
  end

  test "list filters by camera, label, time and stationary_ms; paginates newest-first" do
    now = DateTime.utc_now()
    seed(%{camera_id: "cam_a", started_at: DateTime.add(now, -1 * 86_400), label: "person"})
    seed(%{camera_id: "cam_a", started_at: DateTime.add(now, -2 * 86_400), label: "car"})

    seed(%{
      camera_id: "cam_b",
      started_at: DateTime.add(now, -3 * 86_400),
      label: "person",
      stationary_ms: 30_000
    })

    assert %{total: 3, tracks: [t1, t2, t3]} = Tracks.list()
    assert DateTime.compare(t1.started_at, t2.started_at) == :gt
    assert DateTime.compare(t2.started_at, t3.started_at) == :gt

    assert %{total: 2} = Tracks.list(camera: "cam_a")
    assert %{total: 2} = Tracks.list(label: "person")
    assert %{total: 1} = Tracks.list(camera: "cam_a", label: "person")
    assert %{total: 0} = Tracks.list(label: "person' or 1=1")

    from = DateTime.add(now, -2 * 86_400 - 3600)
    assert %{total: 2} = Tracks.list(from: from)
    assert %{total: 1} = Tracks.list(to: from)

    assert %{total: 1, tracks: [%{camera_id: "cam_b"}]} = Tracks.list(min_stationary_ms: 1)
    assert %{total: 3} = Tracks.list(min_stationary_ms: 0)

    assert %{tracks: [_], total: 3, page: 2} = Tracks.list(page: 2, page_size: 1)
    assert %{tracks: []} = Tracks.list(page: 9, page_size: 2)
  end

  test "moments come back oldest first regardless of insert order" do
    now = DateTime.utc_now()
    later = DateTime.add(now, 10)

    attrs =
      seed(%{}, [moment(:started_moving, later), moment(:appeared, now)])

    assert [%{kind: :appeared}, %{kind: :started_moving}] = Tracks.moments(attrs.id)
  end

  test "insert_batch on an empty batch touches nothing" do
    assert {:ok, %{tracks: 0, moments: 0}} = Tracks.insert_batch([])
  end

  test "a batch SQLite refuses comes back as an error, whole" do
    # The recorder is lossy by design and drops a rejected batch, so the error
    # has to arrive as a value rather than as an exit — and nothing may survive
    # a partial batch.
    # A moment with no `at` fails the *second* statement, after the tracks are
    # already in — so this also pins that the two inserts share a transaction.
    attrs = track_attrs()

    assert {:error, %Exqlite.Error{}} =
             Tracks.insert_batch([{attrs, [%{at: nil, kind: :appeared}]}])

    assert Tracks.get(attrs.id) == nil
  end

  test "a re-offered track id is kept as first written, and does not fail the batch" do
    first_moment = DateTime.utc_now()
    attrs = seed(%{label: "person"}, [moment(:appeared, first_moment)])

    assert {:ok, %{tracks: 0, moments: 1}} =
             Tracks.insert_batch([
               {%{attrs | label: "car"}, [moment(:started_moving, DateTime.add(first_moment, 5))]}
             ])

    # The surviving row is the first batch's, field for field — `:nothing`
    # keeps, it does not merge.
    row = Tracks.get(attrs.id)
    assert row.label == "person"
    assert row.end_reason == :unseen

    # The moments of both batches are on the timeline: only the parent insert is
    # conflict-guarded, which is the duplicate-moment cost the context documents
    # accepting.
    assert [%{kind: :appeared}, %{kind: :started_moving}] = Tracks.moments(attrs.id)
  end
end
