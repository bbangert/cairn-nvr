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

  describe "first_overlapping_event_ids/2" do
    # A clip row, inserted directly: these tests need windows placed to the
    # second around a track, which the capture pipeline's own writers do not
    # expose.
    defp clip(camera_id, started_at, ended_at) do
      %Cairn.Events.Event{}
      |> Cairn.Events.Event.changeset(%{
        id: Ecto.UUID.generate(),
        camera_id: camera_id,
        started_at: started_at,
        ended_at: ended_at,
        status: if(ended_at, do: :finalized, else: :active),
        path: "/tmp/#{System.unique_integer([:positive])}.mp4"
      })
      |> Cairn.Repo.insert!()
    end

    defp track_struct(attrs), do: Tracks.get(seed(attrs).id)

    test "links to the earliest of several overlapping clips" do
      t0 = DateTime.utc_now()

      track =
        track_struct(%{
          camera_id: "cam_a",
          started_at: DateTime.add(t0, 10),
          ended_at: DateTime.add(t0, 200)
        })

      # Inserted late-clip-first, so the expected answer is not also the
      # insertion order. That does not make the `order_by` deletable-and-caught:
      # this query filters on `camera_id` + `started_at`, which SQLite serves
      # from `events_camera_id_started_at_index`, so the rows arrive sorted
      # with or without the clause. What dies here is a reversal to `desc`.
      second = clip("cam_a", DateTime.add(t0, 100), DateTime.add(t0, 160))
      first = clip("cam_a", t0, DateTime.add(t0, 60))

      assert Tracks.first_overlapping_event_ids([track]) == %{track.id => first.id}
      # …and the later clip really does overlap too, so the assertion above is
      # about ordering, not about the second clip being unreachable.
      assert second.started_at |> DateTime.compare(track.ended_at) == :lt
    end

    test "a clip whose window contains the track entirely links" do
      t0 = DateTime.utc_now()

      track =
        track_struct(%{
          camera_id: "cam_a",
          started_at: DateTime.add(t0, 30),
          ended_at: DateTime.add(t0, 40)
        })

      containing = clip("cam_a", t0, DateTime.add(t0, 300))

      assert Tracks.first_overlapping_event_ids([track]) == %{track.id => containing.id}
    end

    test "a track that ends between two clips links to neither" do
      t0 = DateTime.utc_now()

      track =
        track_struct(%{
          camera_id: "cam_a",
          started_at: DateTime.add(t0, 70),
          ended_at: DateTime.add(t0, 90)
        })

      clip("cam_a", t0, DateTime.add(t0, 60))
      clip("cam_a", DateTime.add(t0, 100), DateTime.add(t0, 160))

      assert Tracks.first_overlapping_event_ids([track]) == %{}
    end

    test "overlap is inclusive at both boundaries" do
      t0 = DateTime.utc_now()

      track =
        track_struct(%{
          camera_id: "cam_a",
          started_at: DateTime.add(t0, 100),
          ended_at: DateTime.add(t0, 200)
        })

      # ends exactly when the track starts, and starts exactly when it ends
      before = clip("cam_a", t0, DateTime.add(t0, 100))
      clip("cam_a", DateTime.add(t0, 200), DateTime.add(t0, 300))

      assert Tracks.first_overlapping_event_ids([track]) == %{track.id => before.id}
    end

    test "a clip one second short of the track does not link" do
      t0 = DateTime.utc_now()

      track =
        track_struct(%{
          camera_id: "cam_a",
          started_at: DateTime.add(t0, 100),
          ended_at: DateTime.add(t0, 200)
        })

      clip("cam_a", t0, DateTime.add(t0, 99))

      assert Tracks.first_overlapping_event_ids([track]) == %{}
    end

    test "a still-recording clip has no end, so it overlaps everything after its start" do
      t0 = DateTime.utc_now()

      track =
        track_struct(%{
          camera_id: "cam_a",
          started_at: DateTime.add(t0, 500),
          ended_at: DateTime.add(t0, 520)
        })

      recording = clip("cam_a", t0, nil)

      assert Tracks.first_overlapping_event_ids([track]) == %{track.id => recording.id}
    end

    test "a live track's window runs to now, so a clip opened after it started links" do
      now = DateTime.utc_now()

      track =
        track_struct(%{camera_id: "cam_a", started_at: DateTime.add(now, -600), ended_at: nil})

      later = clip("cam_a", DateTime.add(now, -60), DateTime.add(now, -30))

      assert Tracks.first_overlapping_event_ids([track], now) == %{track.id => later.id}
      # the same clip is out of reach when `now` is taken before it opened
      assert Tracks.first_overlapping_event_ids([track], DateTime.add(now, -300)) == %{}
      assert later.id
    end

    test "a clip on another camera never links, however well the windows line up" do
      t0 = DateTime.utc_now()

      track =
        track_struct(%{
          camera_id: "cam_a",
          started_at: DateTime.add(t0, 10),
          ended_at: DateTime.add(t0, 20)
        })

      clip("cam_b", t0, DateTime.add(t0, 60))

      assert Tracks.first_overlapping_event_ids([track]) == %{}
    end

    test "a page of tracks across cameras resolves in one pass" do
      t0 = DateTime.utc_now()

      a = track_struct(%{camera_id: "cam_a", started_at: t0, ended_at: DateTime.add(t0, 10)})
      b = track_struct(%{camera_id: "cam_b", started_at: t0, ended_at: DateTime.add(t0, 10)})
      c = track_struct(%{camera_id: "cam_c", started_at: t0, ended_at: DateTime.add(t0, 10)})

      clip_a = clip("cam_a", t0, DateTime.add(t0, 30))
      clip_b = clip("cam_b", t0, DateTime.add(t0, 30))

      assert Tracks.first_overlapping_event_ids([a, b, c]) ==
               %{a.id => clip_a.id, b.id => clip_b.id}

      assert c.id
    end

    test "an empty page asks nothing" do
      assert Tracks.first_overlapping_event_ids([]) == %{}
    end
  end

  describe "overlapping_event/3" do
    test "takes every track whose window meets the clip's, and nothing else" do
      t0 = DateTime.utc_now()
      event = clip("cam_a", DateTime.add(t0, 100), DateTime.add(t0, 200))

      # Seeded newest-first, so the expected order is not also the insertion
      # order. As above, that pins the direction of the `order_by` and not its
      # presence: `tracks_camera_id_started_at_index` already returns these
      # rows sorted, so only a reversal to `desc` fails here.
      #
      # started inside, still going long after — the row a read of
      # `tracks.event_id` misses, since it ended with no event open
      spanning = seed(%{started_at: DateTime.add(t0, 150), ended_at: DateTime.add(t0, 9000)})
      # started before the clip, ended inside it
      into = seed(%{started_at: DateTime.add(t0, 50), ended_at: DateTime.add(t0, 150)})
      # wholly before and wholly after
      seed(%{started_at: t0, ended_at: DateTime.add(t0, 90)})
      seed(%{started_at: DateTime.add(t0, 300), ended_at: DateTime.add(t0, 400)})
      # same window, different camera
      seed(%{
        camera_id: "cam_b",
        started_at: DateTime.add(t0, 120),
        ended_at: DateTime.add(t0, 130)
      })

      assert Enum.map(Tracks.overlapping_event(event), & &1.id) == [into.id, spanning.id]
    end

    test "boundaries are inclusive at both ends" do
      t0 = DateTime.utc_now()
      event = clip("cam_a", DateTime.add(t0, 100), DateTime.add(t0, 200))

      # again seeded out of chronological order, so the assertion cannot be
      # satisfied by insertion order alone
      starts_at_end = seed(%{started_at: DateTime.add(t0, 200), ended_at: DateTime.add(t0, 300)})
      ends_at_start = seed(%{started_at: t0, ended_at: DateTime.add(t0, 100)})
      # one millisecond outside each boundary is out
      seed(%{
        started_at: t0,
        ended_at: DateTime.add(t0, 100, :second) |> DateTime.add(-1, :millisecond)
      })

      seed(%{
        started_at: DateTime.add(t0, 200, :second) |> DateTime.add(1, :millisecond),
        ended_at: DateTime.add(t0, 300)
      })

      assert Enum.map(Tracks.overlapping_event(event), & &1.id) ==
               [ends_at_start.id, starts_at_end.id]
    end

    test "limit: takes the earliest n, and one more than n is how a caller sees truncation" do
      t0 = DateTime.utc_now()
      event = clip("cam_a", t0, DateTime.add(t0, 300))

      # seeded newest-first: the limit must cut by `started_at`, not by rowid
      third = seed(%{started_at: DateTime.add(t0, 30), ended_at: DateTime.add(t0, 40)})
      second = seed(%{started_at: DateTime.add(t0, 20), ended_at: DateTime.add(t0, 30)})
      first = seed(%{started_at: DateTime.add(t0, 10), ended_at: DateTime.add(t0, 20)})

      assert Enum.map(Tracks.overlapping_event(event, t0, limit: 2), & &1.id) ==
               [first.id, second.id]

      # asking for one more than the cap is what tells the caller it truncated:
      # three rows back for a limit of 3 means there may be a fourth
      assert length(Tracks.overlapping_event(event, t0, limit: 3)) == 3
      # …and with the cap above the row count, the extra row never arrives
      assert Enum.map(Tracks.overlapping_event(event, t0, limit: 4), & &1.id) ==
               [first.id, second.id, third.id]

      # no limit is still no limit
      assert length(Tracks.overlapping_event(event, t0)) == 3
    end

    test "a live track overlaps a clip that has already ended" do
      t0 = DateTime.utc_now()
      event = clip("cam_a", DateTime.add(t0, -600), DateTime.add(t0, -500))
      live = seed(%{started_at: DateTime.add(t0, -550), ended_at: nil})

      assert Enum.map(Tracks.overlapping_event(event), & &1.id) == [live.id]
    end

    test "a still-recording clip's window ends at `now`" do
      t0 = DateTime.utc_now()
      recording = clip("cam_a", DateTime.add(t0, -600), nil)
      recent = seed(%{started_at: DateTime.add(t0, -60), ended_at: DateTime.add(t0, -30)})

      assert Enum.map(Tracks.overlapping_event(recording, t0), & &1.id) == [recent.id]
      # asked as of a moment before that track existed, the clip has not
      # reached it yet
      assert Tracks.overlapping_event(recording, DateTime.add(t0, -300)) == []
    end
  end

  describe "moment_clips/3" do
    test "sorts instants into this clip, another clip, and no clip at all" do
      t0 = DateTime.utc_now()
      here = clip("cam_a", t0, DateTime.add(t0, 60))
      other = clip("cam_a", DateTime.add(t0, 500), DateTime.add(t0, 560))

      inside = DateTime.add(t0, 10)
      gap = DateTime.add(t0, 200)
      elsewhere = DateTime.add(t0, 520)

      assert Tracks.moment_clips([inside, gap, elsewhere], "cam_a", here.id) == %{
               inside => :here,
               gap => :none,
               elsewhere => {:other, other.id, 20}
             }
    end

    test "a clip on another camera contains nothing" do
      t0 = DateTime.utc_now()
      clip("cam_b", t0, DateTime.add(t0, 60))
      at = DateTime.add(t0, 10)

      assert Tracks.moment_clips([at], "cam_a", nil) == %{at => :none}
    end

    test "a still-recording clip contains everything after its start" do
      t0 = DateTime.utc_now()
      recording = clip("cam_a", t0, nil)
      before = DateTime.add(t0, -1)
      after_start = DateTime.add(t0, 3_600)

      assert Tracks.moment_clips([before, after_start], "cam_a", nil) == %{
               before => :none,
               after_start => {:other, recording.id, 3_600}
             }
    end

    test "containment is inclusive at both edges" do
      t0 = DateTime.utc_now()
      c = clip("cam_a", t0, DateTime.add(t0, 60))
      just_before = DateTime.add(t0, -1, :millisecond)
      just_after = DateTime.add(t0, 60, :second) |> DateTime.add(1, :millisecond)

      assert Tracks.moment_clips([t0], "cam_a", c.id) == %{t0 => :here}

      assert Tracks.moment_clips([DateTime.add(t0, 60)], "cam_a", c.id) == %{
               DateTime.add(t0, 60) => :here
             }

      assert Tracks.moment_clips([just_before, just_after], "cam_a", c.id) == %{
               just_before => :none,
               just_after => :none
             }
    end

    test "no instants asks nothing" do
      assert Tracks.moment_clips([], "cam_a", "whatever") == %{}
    end
  end

  describe "moments_for/1" do
    test "groups many tracks' moments, oldest first inside each" do
      t0 = DateTime.utc_now()

      a =
        seed(%{}, [
          moment(:started_moving, DateTime.add(t0, 9)),
          moment(:appeared, DateTime.add(t0, 1)),
          moment(:became_stationary, DateTime.add(t0, 4))
        ])

      b = seed(%{}, [moment(:appeared, DateTime.add(t0, 2))])
      quiet = seed(%{}, [])

      grouped = Tracks.moments_for([a.id, b.id, quiet.id])

      assert Enum.map(grouped[a.id], & &1.kind) == [
               :appeared,
               :became_stationary,
               :started_moving
             ]

      assert Enum.map(grouped[b.id], & &1.kind) == [:appeared]
      # a track with no moments is absent, not an empty list
      refute Map.has_key?(grouped, quiet.id)
    end

    test "an id with no track answers nothing, and an empty list asks nothing" do
      assert Tracks.moments_for([Cairn.ULID.generate()]) == %{}
      assert Tracks.moments_for([]) == %{}
    end
  end

  test "known_labels and known_zones list the distinct values, sorted" do
    seed(%{label: "person", zones: ["porch", "walkway"]})
    seed(%{label: "car", zones: ["driveway", "porch"]})
    seed(%{label: "person", zones: []})
    seed(%{label: nil, zones: ["driveway"]})

    assert Tracks.known_labels() == ["car", "person"]
    assert Tracks.known_zones() == ["driveway", "porch", "walkway"]
  end

  test "known_labels and known_zones collapse the duplicates in SQL, not in Elixir" do
    # 60 rows, 120 zone entries, two of each value. Neither function sorts or
    # dedups what SQLite hands back, so a result longer than the distinct set
    # is a `DISTINCT` that stopped happening in the database — the whole point
    # of these two queries on a table that keeps a row per tracked object for
    # 365 days.
    for i <- 1..30 do
      seed(%{label: "person", zones: ["porch", "walkway"], started_at: DateTime.utc_now()})
      seed(%{label: "car", zones: ["driveway"], started_at: DateTime.add(DateTime.utc_now(), -i)})
    end

    assert %{total: 60} = Tracks.list()
    assert Tracks.known_labels() == ["car", "person"]
    assert Tracks.known_zones() == ["driveway", "porch", "walkway"]
  end

  test "zone filter matches array membership and pages on the filtered set" do
    now = DateTime.utc_now()
    driveway = seed(%{zones: ["driveway", "porch"], started_at: now})
    porch_only = seed(%{zones: ["porch"], started_at: DateTime.add(now, -60)})
    zoneless = seed(%{zones: [], started_at: DateTime.add(now, -120)})

    assert %{total: 1, tracks: [row]} = Tracks.list(zone: "driveway")
    assert row.id == driveway.id
    assert row.zones == ["driveway", "porch"]

    assert %{total: 2, tracks: rows} = Tracks.list(zone: "porch")
    assert Enum.map(rows, & &1.id) == [driveway.id, porch_only.id]

    # no match, and a row with an empty zones array is never a match
    assert %{total: 0, tracks: []} = Tracks.list(zone: "sidewalk")
    refute zoneless.id in Enum.map(Tracks.list(zone: "porch").tracks, & &1.id)

    # substring and quoting attempts are compared as whole values, pinned
    assert %{total: 0} = Tracks.list(zone: "porc")
    assert %{total: 0} = Tracks.list(zone: "porch' OR 1=1 --")

    # `total` reflects the filter, not the table: 2 of 3 rows match, so page 2
    # of size 1 is the second match and page 3 is empty
    assert %{total: 2, page: 2, tracks: [second]} =
             Tracks.list(zone: "porch", page: 2, page_size: 1)

    assert second.id == porch_only.id
    assert %{total: 2, tracks: []} = Tracks.list(zone: "porch", page: 3, page_size: 1)
  end

  test "zone filter passes through on nil and empty string" do
    seed(%{zones: ["driveway"]})
    seed(%{zones: []})

    assert %{total: 2} = Tracks.list(zone: nil)
    assert %{total: 2} = Tracks.list(zone: "")
    assert %{total: 2} = Tracks.list()
    # combines with the other filters rather than replacing them
    assert %{total: 1} = Tracks.list(zone: "driveway", camera: "cam_a")
    assert %{total: 0} = Tracks.list(zone: "driveway", camera: "cam_b")
  end

  test "moments come back oldest first regardless of insert order" do
    now = DateTime.utc_now()
    later = DateTime.add(now, 10)

    attrs =
      seed(%{}, [moment(:started_moving, later), moment(:appeared, now)])

    assert [%{kind: :appeared}, %{kind: :started_moving}] = Tracks.moments(attrs.id)
  end

  test "a float stationary_ms from the observation clock is rounded at the boundary" do
    # The observation clock is float arithmetic; the column is :integer
    # and insert_all dumps without casting. The crash this pins ate the
    # recorder's buffer live (Ecto.ChangeError on 4366.666666666666).
    attrs = track_attrs(%{stationary_ms: 4366.666666666666})
    assert {:ok, %{tracks: 1}} = Tracks.insert_batch([{attrs, []}])
    assert Tracks.get(attrs.id).stationary_ms == 4367
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

  describe "upsert" do
    test "a re-offered track id rewrites its row rather than adding one" do
      # The live-row path in one call pair: a row opened while the track runs,
      # then the same id offered again to close it.
      opened = DateTime.utc_now()

      attrs =
        seed(
          %{
            camera_id: "cam_upsert",
            label: "person",
            best_score: 0.6,
            ended_at: nil,
            entry_bbox: [1, 1, 2, 2]
          },
          [moment(:appeared, opened, [1, 1, 2, 2])]
        )

      before = Tracks.get(attrs.id)
      assert before.ended_at == nil

      closed =
        Map.merge(attrs, %{
          label: "car",
          best_score: 0.82,
          ended_at: DateTime.add(opened, 30),
          end_reason: :unseen,
          stationary_ms: 4_000,
          exit_bbox: [9, 9, 1, 1],
          # what a later write cannot know: `entry_bbox` came from the
          # `:appeared` moment, and `camera_id` is the track's identity
          entry_bbox: nil,
          camera_id: "cam_elsewhere"
        })

      assert {:ok, %{tracks: 1, moments: 1}} =
               Tracks.insert_batch([{closed, [moment(:started_moving, DateTime.add(opened, 5))]}])

      row = Tracks.get(attrs.id)
      # replaced
      assert row.label == "car"
      assert row.best_score == 0.82
      assert row.end_reason == :unseen
      assert DateTime.compare(row.ended_at, DateTime.add(opened, 30)) == :eq
      assert row.stationary_ms == 4_000
      assert row.exit_bbox == [9, 9, 1, 1]
      # kept
      assert row.camera_id == "cam_upsert"
      assert row.entry_bbox == [1, 1, 2, 2]
      assert row.inserted_at == before.inserted_at
      # `updated_at` moves, and has to: `close_live/0` reads it as the instant
      # the row was last known live
      assert DateTime.compare(row.updated_at, before.updated_at) == :gt

      # one row, not two — the whole point of the conflict target
      assert Tracks.list(camera: "cam_upsert").total == 1

      # The moments of both writes are on the timeline: only the parent insert
      # is conflict-guarded, which is the duplicate-moment cost the context
      # documents accepting.
      assert [%{kind: :appeared}, %{kind: :started_moving}] = Tracks.moments(attrs.id)
    end

    test "a live row's nil ended_at and end_reason are written, not merely absent" do
      # Ecto's `insert_all` has no notion of a partial row, so this pins the
      # other direction of the replace list: closing a row and then re-offering
      # it live would blank both columns.
      attrs = seed(%{ended_at: DateTime.utc_now(), end_reason: :unseen})
      assert Tracks.get(attrs.id).end_reason == :unseen

      {:ok, _} = Tracks.insert_batch([{%{attrs | ended_at: nil, end_reason: nil}, []}])

      row = Tracks.get(attrs.id)
      assert row.ended_at == nil
      assert row.end_reason == nil
    end
  end

  describe "close_live/0" do
    test "closes a live row at its own updated_at, as :host_restart" do
      live = seed(%{ended_at: nil, end_reason: nil})
      ended_at = DateTime.add(DateTime.utc_now(), -60)
      already = seed(%{ended_at: ended_at, end_reason: :plugin_ended})
      before = Tracks.get(live.id)

      assert Tracks.close_live() == 1

      row = Tracks.get(live.id)
      assert row.end_reason == :host_restart
      # the instant the row was last known live, not the clock of this call
      assert row.updated_at == before.updated_at
      assert row.ended_at == before.updated_at

      # a row that closed itself is left exactly as it was
      untouched = Tracks.get(already.id)
      assert untouched.end_reason == :plugin_ended
      assert DateTime.compare(untouched.ended_at, ended_at) == :eq
    end

    test "a closed row is not closed twice, and a later write still wins" do
      live = seed(%{ended_at: nil, end_reason: nil})

      assert Tracks.close_live() == 1
      assert Tracks.close_live() == 0

      # A camera tracker's checkpoint restore, arriving after the boot-time close:
      # both say `:host_restart`, and the restore's own `last_seen_at` replaces
      # the derived one.
      last_seen = DateTime.add(DateTime.utc_now(), -5)

      {:ok, _} =
        Tracks.insert_batch([{%{live | ended_at: last_seen, end_reason: :host_restart}, []}])

      row = Tracks.get(live.id)
      assert DateTime.compare(row.ended_at, last_seen) == :eq
      assert row.end_reason == :host_restart
      assert Tracks.close_live() == 0
    end
  end
end
