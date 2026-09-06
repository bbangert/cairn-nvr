defmodule Cairn.PresenceRecorderRestoreTest do
  # `Cairn.DataCase`, unlike `Cairn.PresenceRecorderTest`: restore consults the
  # event index to decide whether an orphaned event still needs announcing, and
  # both answers — no row, and a row the extractor already finalized — need a
  # reachable index to tell apart. The tolerance for an index that will NOT
  # answer is proved where that is the natural state, in the sibling suite.
  #
  # Not async: these cases kill processes in the application's own presence
  # tree, and several subscribe to the shared "events" topic.
  use Cairn.DataCase, async: false

  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias Cairn.Config.Camera

  import Cairn.PresenceFixtures, only: [frame: 1, object: 4, relay: 1, relay_loop: 1]

  alias Cairn.{
    CameraControl,
    Event,
    EventCheckpoint,
    Events,
    PresenceAggregator,
    PresenceCheckpoint,
    PresenceEvent,
    PresenceLedger,
    PresenceRecorder,
    Registry
  }

  @policy %{pre: 5, post: 10, max: 300, record: nil}

  setup do
    camera_id = "prest_#{System.unique_integer([:positive])}"
    # The checkpoint owner drops a write for a camera the fleet does not name.
    Cairn.SnapshotHelpers.lend_cameras(camera_id)
    camera = %Camera{id: camera_id, rtsp_url: "rtsp://h/1", min_score: %{"default" => 0.5}}

    Event.subscribe()

    on_exit(fn ->
      PresenceCheckpoint.delete(camera_id)

      for {zone, label, _at, _score} <- PresenceLedger.leftovers(camera_id),
          do: PresenceLedger.cleared(camera_id, zone, label)
    end)

    %{camera_id: camera_id, camera: camera}
  end

  defp frames(ctx, objects) do
    PresenceRecorder.frames(ctx.camera_id, %{"default" => 0.5}, [frame(objects)])
  end

  defp recorder(ctx, id \\ :recorder) do
    test_pid = self()
    camera = ctx.camera

    start_supervised!(
      {PresenceRecorder,
       camera_id: ctx.camera_id,
       resolve_policy: fn _camera_id -> {camera, @policy} end,
       start_extractor: fn _camera, event ->
         pid = relay(test_pid)
         send(test_pid, {:extractor_started, event, pid})
         {:ok, pid}
       end,
       finalize_extractor: fn pid, event ->
         send(test_pid, {:extractor_finalized, pid, event})
       end},
      id: id
    )
  end

  defp event(ctx, labels \\ %{"person" => 0.9}) do
    %Event{
      id: Ecto.UUID.generate(),
      camera_id: ctx.camera_id,
      started_at: DateTime.add(DateTime.utc_now(), -30),
      status: :active,
      labels: for({label, score} <- labels, do: %{t: +0.0, label: label, score: score}),
      max_scores: labels,
      max_score: labels |> Map.values() |> Enum.max()
    }
  end

  defp presence(ctx, label, score, zone) do
    now = DateTime.utc_now()

    %PresenceEvent{
      camera_id: ctx.camera_id,
      zone: zone,
      label: label,
      score: score,
      first_seen_at: now,
      at: now
    }
  end

  defp started(ctx, label \\ "person", score \\ 0.9, zone \\ nil) do
    PresenceRecorder.presence(ctx.camera_id, :presence_started, presence(ctx, label, score, zone))
  end

  defp cleared(ctx, label \\ "person", score \\ 0.9, zone \\ nil) do
    PresenceRecorder.presence(ctx.camera_id, :presence_cleared, presence(ctx, label, score, zone))
  end

  # The ledger row the aggregator writes before a `presence_started` goes out.
  # Restore intersects the checkpoint's keys with these, so a test restoring a
  # present key has to leave the trace the aggregator would have.
  # An extractor that outlived every witness to its event: registered exactly
  # where `Cairn.EventExtractor` registers itself, which is all the sweep has to
  # find it by.
  defp registered_relay(camera_id, event_id, test_pid) do
    spawn(fn ->
      {:ok, _} = Cairn.Registry.register(camera_id, {:extractor, event_id})
      Process.monitor(test_pid)
      relay_loop(test_pid)
    end)
  end

  defp await_extractor(camera_id, event_id, attempts \\ 100) do
    case Registry.whereis(camera_id, {:extractor, event_id}) do
      pid when is_pid(pid) ->
        pid

      _absent when attempts > 0 ->
        Process.sleep(10) && await_extractor(camera_id, event_id, attempts - 1)

      _absent ->
        flunk("the stand-in extractor never registered")
    end
  end

  # The sweep's two messages arrive by different routes — one over the events
  # topic, one straight from the finalize seam — so they are taken in mailbox
  # order to assert the order itself, not merely that both came.
  defp next_sweep_message(timeout \\ 2_000) do
    receive do
      {:event_ended, %Event{}} = message -> message
      {:extractor_finalized, _pid, _event} = message -> message
    after
      timeout -> flunk("the sweep said nothing within #{timeout}ms")
    end
  end

  defp announce(ctx, label, score \\ 0.9, zone \\ nil) do
    PresenceLedger.announced(ctx.camera_id, zone, label, DateTime.utc_now(), score)
  end

  defp fire(recorder, kind, event_id) do
    key = if kind == :post_window, do: :post_token, else: :max_token
    send(recorder, {kind, event_id, :sys.get_state(recorder)[key]})
  end

  defp await_recorder(camera_id, not_pid, attempts \\ 200) do
    case Registry.whereis(camera_id, :presence_recorder) do
      pid when is_pid(pid) and pid != not_pid ->
        pid

      _absent when attempts > 0 ->
        Process.sleep(10)
        await_recorder(camera_id, not_pid, attempts - 1)

      _absent ->
        flunk("no replacement recorder was registered for #{camera_id}")
    end
  end

  # -- checkpoint restore -----------------------------------------------------

  test "a live extractor is adopted, with the camera's own windows re-armed", ctx do
    extractor = relay(self())
    event = event(ctx)
    eid = event.id
    # the aggregator still holds the label, which is what makes it a present
    # one rather than a ghost (`still_announced/2`)
    announce(ctx, "person")
    PresenceCheckpoint.put!(ctx.camera_id, event, [{nil, "person"}], extractor)

    rec = recorder(ctx)

    state = :sys.get_state(rec)
    assert state.event.id == eid
    assert state.extractor == extractor
    assert state.present_labels == MapSet.new([{nil, "person"}])
    assert state.present_scores == %{{nil, "person"} => 0.9}
    # a label is still present, so only the cap runs; the close clock waits for
    # the clear that has not happened
    assert state.max_token != nil
    assert state.post_token == nil
    # nothing is re-announced: the event was already broadcast as started by
    # the process that opened it
    refute_received {:event_started, %Event{id: ^eid}}

    # the adopted extractor is the one the close talks to, boxes and all
    cleared(ctx)
    assert :sys.get_state(rec).post_token != nil
    fire(rec, :post_window, eid)

    assert_receive {:event_ended, %Event{id: ^eid, status: :finalized}}
    assert_receive {:extractor_finalized, ^extractor, %Event{id: ^eid}}
    assert PresenceCheckpoint.get(ctx.camera_id) == nil
  end

  # The adopted extractor is still buffering the same sidecar, so a
  # replacement recorder that re-minted slots from zero could connect a new
  # box to an unrelated pre-crash path and interpolate across the frame. The
  # centres ride the checkpoint; the first post-restore frame continues its
  # path.
  test "restored slot centres keep a sidecar path across the crash", ctx do
    extractor = relay(self())
    event = event(ctx)
    announce(ctx, "person")

    PresenceCheckpoint.put!(ctx.camera_id, event, [{nil, "person"}], extractor, %{
      centers: %{"person" => %{1 => {0.55, 0.35}}},
      next: %{"person" => 2}
    })

    recorder(ctx)

    # Centre 0.55 — inside the restored slot 1's radius: the box continues
    # its slot-1 path instead of minting "person" from an empty slot table.
    frames(ctx, [object("person", 0.9, "detected", [0.5, 0.2, 0.1, 0.3])])
    assert_receive {:extractor_cast, {:track_boxes, %{boxes: [{"person\u001F1", _, _, _, _}]}}}
  end

  # The cap timer gets the remainder, not a fresh window: a restart must not
  # stretch a clip past the advertised max_event_seconds. An event already past
  # it closes on arrival, and segmentation keeps the coverage.
  test "a restored event past its cap closes now and segments", ctx do
    extractor = relay(self())
    event = %{event(ctx) | started_at: DateTime.add(DateTime.utc_now(), -400)}
    eid = event.id
    announce(ctx, "person")
    PresenceCheckpoint.put!(ctx.camera_id, event, [{nil, "person"}], extractor)

    # @policy max is 300; 400 s spent means the remainder is negative and the
    # timer fires immediately — no fire/3 helper, the real timer does it.
    recorder(ctx)

    assert_receive {:event_ended, %Event{id: ^eid, status: :finalized}}, 2_000
    assert_receive {:extractor_finalized, ^extractor, %Event{id: ^eid}}

    # the label is still present and announced: the next clip opens by itself
    assert_receive {:event_started, %Event{camera_id: _, id: new_id}}, 2_000
    assert new_id != eid
  end

  # `max_scores` is the best over the whole EVENT and the ledger row is the
  # current stay's, improved by everything the aggregator saw while this process
  # was down — including a label that cleared and came back lower.
  test "a re-attached label takes its score from the ledger, not from the event", ctx do
    extractor = relay(self())
    event = event(ctx, %{"person" => 0.9})
    announce(ctx, "person", 0.4)
    PresenceCheckpoint.put!(ctx.camera_id, event, [{nil, "person"}], extractor)

    rec = recorder(ctx)

    state = :sys.get_state(rec)
    assert state.present_labels == MapSet.new([{nil, "person"}])
    assert state.present_scores == %{{nil, "person"} => 0.4}
    # the event keeps its own history: only what a next segment would claim
    # comes from the ledger
    assert state.event.max_scores == %{"person" => 0.9}
  end

  # `cleared/2` checkpoints that edge past the throttle precisely so this can
  # be read back: a row naming no labels is one whose close clock was already
  # running, and nothing is coming to start it again.
  test "a restored row with no labels left re-arms the close clock", ctx do
    extractor = relay(self())
    event = event(ctx)
    eid = event.id
    PresenceCheckpoint.put!(ctx.camera_id, event, [], extractor)

    rec = recorder(ctx)

    state = :sys.get_state(rec)
    assert state.present_labels == MapSet.new()
    assert state.post_token != nil

    fire(rec, :post_window, eid)
    assert_receive {:event_ended, %Event{id: ^eid, status: :finalized}}
  end

  # The clear that was emitted while the recorder was dying: the ledger row went
  # with it, the cast did not survive the dead pid, and nothing will ever say
  # that label again. Restored, it would hold the close clock hostage on this
  # event and — since the post window is armed by the LAST label leaving — on
  # every later event this camera has.
  test "a checkpoint label the ledger no longer announces is not restored as present", ctx do
    extractor = relay(self())
    event = event(ctx)
    eid = event.id
    PresenceCheckpoint.put!(ctx.camera_id, event, [{nil, "person"}], extractor)

    rec = recorder(ctx)

    state = :sys.get_state(rec)
    # the event is adopted — its clip is still being written…
    assert state.event.id == eid
    assert state.extractor == extractor
    # …but nothing is holding it open, so the close clock runs
    assert state.present_labels == MapSet.new()
    assert state.present_scores == %{}
    assert state.post_token != nil

    fire(rec, :post_window, eid)
    assert_receive {:event_ended, %Event{id: ^eid, status: :finalized}}
    assert_receive {:extractor_finalized, ^extractor, %Event{id: ^eid}}
  end

  test "an extractor that died with its recorder leaves an orphan ended partial", ctx do
    dead = relay(self())
    Process.exit(dead, :kill)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, :process, ^dead, _reason}

    event = event(ctx)
    eid = event.id
    PresenceCheckpoint.put!(ctx.camera_id, event, [{nil, "person"}], dead)

    rec = recorder(ctx)

    assert_receive {:event_ended, %Event{id: ^eid, status: :partial}}
    assert PresenceCheckpoint.get(ctx.camera_id) == nil

    state = :sys.get_state(rec)
    assert state.event == nil
    assert state.extractor == nil
  end

  # The ledger is keyed by the whole `{zone, label}`, so a checkpoint key whose
  # zone no longer announces is a ghost even while the same label is announced
  # from another zone.
  test "a checkpoint with zoned keys restores them against the zoned ledger rows", ctx do
    extractor = relay(self())
    event = event(ctx)
    announce(ctx, "person", 0.8, "drive")

    PresenceCheckpoint.put!(
      ctx.camera_id,
      event,
      [{"drive", "person"}, {"porch", "person"}],
      extractor
    )

    rec = recorder(ctx)

    state = :sys.get_state(rec)
    assert state.present_labels == MapSet.new([{"drive", "person"}])
    assert state.present_scores == %{{"drive", "person"} => 0.8}
    # a key is still present, so only the cap runs
    assert state.post_token == nil
  end

  # The crash window includes "the finalize cast was already in the extractor's
  # mailbox": it finalized the row and announced the clip before exiting, and
  # re-announcing that event `:partial` would both invert the artifact ordering
  # and mislabel a clean event. The index, which the extractor wrote, decides.
  test "an orphan the extractor had already finalized is not announced again", ctx do
    event = event(ctx)
    eid = event.id
    {:ok, _row} = Events.create_active(event, "/tmp/#{eid}.mp4")
    {:ok, _row} = Events.finalize(%{event | ended_at: DateTime.utc_now()}, 1_024)

    PresenceCheckpoint.put!(ctx.camera_id, event, [{nil, "person"}], nil)

    rec = recorder(ctx)

    _ = :sys.get_state(rec)
    refute_received {:event_ended, %Event{id: ^eid}}
    assert PresenceCheckpoint.get(ctx.camera_id) == nil
    assert :sys.get_state(rec).event == nil
  end

  # The same reasoning one step later: the finalize was in flight, so the
  # adopted extractor does its work and exits `:normal` after this process
  # restored the row. An extractor this process started itself is read the
  # other way (`Cairn.PresenceRecorderTest`), and that difference is what the
  # `adopted_extractor?` flag is for.
  test "an adopted extractor that finalizes after the restore ends quietly", ctx do
    extractor = relay(self())
    event = event(ctx)
    eid = event.id
    {:ok, _row} = Events.create_active(event, "/tmp/#{eid}.mp4")
    {:ok, _row} = Events.finalize(%{event | ended_at: DateTime.utc_now()}, 1_024)
    PresenceCheckpoint.put!(ctx.camera_id, event, [{nil, "person"}], extractor)

    rec = recorder(ctx)
    assert :sys.get_state(rec).extractor == extractor

    Process.exit(extractor, :kill)
    ref = Process.monitor(extractor)
    assert_receive {:DOWN, ^ref, :process, ^extractor, _reason}
    assert await_cleared_event(rec)

    refute_received {:event_ended, %Event{id: ^eid}}
  end

  # The r4 hazard: a recorder crash leaves the extractor alive with the timers
  # gone, and a clear or a re-confirm after the restore must reach the RESTORED
  # event. A second event opened beside the orphan would give the camera two
  # clips for one scene and two `:event_started` for one presence.
  test "a recorder crash mid-event re-attaches instead of opening a second event", ctx do
    id = ctx.camera_id
    rec = recorder(ctx)

    started(ctx)
    assert_receive {:extractor_started, %Event{id: eid}, extractor}
    assert_receive {:event_started, %Event{id: ^eid}}
    # the checkpoint is written inside the open; draining is what proves it
    _ = :sys.get_state(rec)

    Process.exit(rec, :kill)
    restored = await_recorder(id, rec)

    state = :sys.get_state(restored)
    assert state.event.id == eid
    assert state.extractor == extractor
    assert state.adopted_extractor?

    # a re-confirm extends the restored event…
    started(ctx, "car", 0.7)
    assert_receive {:event_updated, %Event{id: ^eid, max_scores: %{"car" => 0.7}}}
    refute_received {:event_started, %Event{camera_id: ^id}}

    # …and the clears close that one, once, on the re-armed timers
    cleared(ctx, "person")
    cleared(ctx, "car")
    assert :sys.get_state(restored).post_token != nil

    fire(restored, :post_window, eid)
    assert_receive {:event_ended, %Event{id: ^eid, status: :finalized}}
    assert_receive {:extractor_finalized, ^extractor, %Event{id: ^eid}}
    refute_received {:event_ended, %Event{camera_id: ^id}}
  end

  # A checkpoint-table crash empties the ledger with it (`:rest_for_one`) while
  # the extractors — app-level siblings under `Cairn.EventSupervisor` — keep
  # writing, so a recorder restarting after one finds both witnesses to its
  # event gone. Nothing else would ever end it (an extractor has no cap of its
  # own), and the camera's next confirm would open a second one beside it.
  test "an extractor still writing with no checkpoint is ended partial, then replaced", ctx do
    id = ctx.camera_id
    event = event(ctx)
    eid = event.id
    {:ok, _row} = Events.create_active(event, "/tmp/#{eid}.mp4")
    stranded = registered_relay(id, eid, self())
    assert await_extractor(id, eid) == stranded
    assert PresenceCheckpoint.get(id) == nil

    rec = recorder(ctx)

    # ended before finalized, `maybe_finalize/3`'s ordering — and the labels the
    # row earned ride back with it, since the extractor writes what it is handed
    assert [
             {:event_ended,
              %Event{id: ^eid, status: :partial, max_scores: %{"person" => 0.9}, max_score: 0.9}},
             {:extractor_finalized, ^stranded, %Event{id: ^eid}}
           ] = [next_sweep_message(), next_sweep_message()]

    # not adopted: with no checkpoint there is nothing to carry on with
    assert :sys.get_state(rec).event == nil

    # and the presence that is still there gets its own clip — one, not one
    # beside an orphan that never ends
    started(ctx)
    assert_receive {:extractor_started, %Event{id: fresh}, _pid}
    assert_receive {:event_started, %Event{id: ^fresh}}
    assert fresh != eid
    refute_received {:event_started, %Event{camera_id: ^id}}
  end

  test "an active row whose extractor is gone is left to boot reconciliation", ctx do
    id = ctx.camera_id
    event = event(ctx)
    eid = event.id
    {:ok, _row} = Events.create_active(event, "/tmp/#{eid}.mp4")

    rec = recorder(ctx)

    _ = :sys.get_state(rec)
    refute_received {:event_ended, %Event{id: ^eid}}
    refute_received {:extractor_finalized, _pid, _event}
    assert Events.get(eid).status == :active
    assert Registry.whereis(id, {:extractor, eid}) == nil
  end

  # The index says nothing about which lane wrote a row (D-E7), and a camera
  # flipping from tier 2 to tier 1 starts a recorder while the tracked event it
  # had is still being written. `Cairn.EventCheckpoint` is that lane's own
  # witness to a live event, and what it names is not this lane's to end.
  test "a row the tracked lane still has open is not swept", ctx do
    id = ctx.camera_id
    event = event(ctx)
    eid = event.id
    {:ok, _row} = Events.create_active(event, "/tmp/#{eid}.mp4")
    tracked = registered_relay(id, eid, self())
    assert await_extractor(id, eid) == tracked
    EventCheckpoint.put!(id, event)
    on_exit(fn -> EventCheckpoint.delete(id) end)

    rec = recorder(ctx)

    _ = :sys.get_state(rec)
    refute_received {:event_ended, %Event{id: ^eid}}
    refute_received {:extractor_finalized, _pid, _event}
    assert Events.get(eid).status == :active
  end

  # -- the ledger read --------------------------------------------------------

  # The started this process was down for. Nothing else will ever mention that
  # label: the aggregator holds it as `:present`, and a present label does not
  # confirm a second time before it has cleared.
  test "an announced label with no checkpoint opens an event on restart", ctx do
    id = ctx.camera_id
    PresenceLedger.announced(id, nil, "person", DateTime.add(DateTime.utc_now(), -20), 0.9)

    rec = recorder(ctx)

    assert_receive {:extractor_started, %Event{id: eid, max_scores: %{"person" => 0.9}}, _pid}
    assert_receive {:event_started, %Event{id: ^eid}}

    state = :sys.get_state(rec)
    assert state.present_labels == MapSet.new([{nil, "person"}])
    # dated from the restart, not from when the label was first seen: the clip
    # reaches no further back than the ring's pre-window
    assert DateTime.diff(DateTime.utc_now(), state.event.started_at, :millisecond) < 5_000

    # the ledger row is the aggregator's to clear, and is still there for it
    assert [{nil, "person", _at, 0.9}] = PresenceLedger.leftovers(id)
  end

  # The same started, announced from a zone: the present set keeps the zone, and
  # the event it opens is keyed by the label alone.
  test "an announced zoned key opens an event keyed by its label", ctx do
    id = ctx.camera_id
    PresenceLedger.announced(id, "drive", "person", DateTime.add(DateTime.utc_now(), -20), 0.9)

    rec = recorder(ctx)

    assert_receive {:extractor_started, %Event{id: eid, max_scores: %{"person" => 0.9}}, _pid}
    assert_receive {:event_started, %Event{id: ^eid}}

    state = :sys.get_state(rec)
    assert state.present_labels == MapSet.new([{"drive", "person"}])
    assert [%{label: "person", score: 0.9}] = state.event.labels
  end

  test "an announced label the record: tier refuses is not adopted", ctx do
    id = ctx.camera_id
    test_pid = self()
    camera = ctx.camera
    PresenceLedger.announced(id, nil, "cat", DateTime.utc_now(), 0.95)

    rec =
      start_supervised!(
        {PresenceRecorder,
         camera_id: id,
         resolve_policy: fn _camera_id ->
           {camera, %{@policy | record: %{"person" => %{min_score: 0.6}}}}
         end,
         start_extractor: fn _camera, event ->
           pid = relay(test_pid)
           send(test_pid, {:extractor_started, event, pid})
           {:ok, pid}
         end,
         finalize_extractor: fn _pid, _event -> :ok end},
        id: :refusing_recorder
      )

    state = :sys.get_state(rec)
    assert state.event == nil
    assert state.present_labels == MapSet.new()
    refute_received {:event_started, %Event{camera_id: ^id}}
  end

  test "a label the restored checkpoint already names is not adopted twice", ctx do
    id = ctx.camera_id
    extractor = relay(self())
    event = event(ctx)
    eid = event.id
    PresenceCheckpoint.put!(id, event, [{nil, "person"}], extractor)
    PresenceLedger.announced(id, nil, "person", DateTime.utc_now(), 0.9)

    rec = recorder(ctx)

    state = :sys.get_state(rec)
    assert state.event.id == eid
    assert state.present_labels == MapSet.new([{nil, "person"}])
    refute_received {:event_started, %Event{camera_id: ^id}}
  end

  # The ledger is keyed `{camera, zone, label}` and read with a partially bound
  # key; a pattern that let another camera's rows through would adopt its keys
  # here, on a camera that never saw them.
  test "another camera's announced labels are not adopted", ctx do
    other = "prest_other_#{System.unique_integer([:positive])}"
    PresenceLedger.announced(other, nil, "person", DateTime.utc_now(), 0.9)
    on_exit(fn -> PresenceLedger.cleared(other, nil, "person") end)

    rec = recorder(ctx)

    state = :sys.get_state(rec)
    assert state.event == nil
    assert state.present_labels == MapSet.new()
    assert PresenceLedger.leftovers(ctx.camera_id) == []
    # …and the other camera's row is still there to be read by its own recorder
    assert [{nil, "person", _at, 0.9}] = PresenceLedger.leftovers(other)
  end

  # `Cairn.EventExtractor.start/3` is a call into a DynamicSupervisor, so it
  # *exits* while that supervisor is briefly absent — and the ledger read can
  # reach it from `init/1`. Unguarded, the crash repeats on every restart
  # (reading the ledger does not consume it) and three of those take the pool
  # and both presence tables down with them.
  test "an extractor start that exits leaves the lane up rather than crash-looping", ctx do
    id = ctx.camera_id
    camera = ctx.camera
    announce(ctx, "person")

    log =
      capture_log(fn ->
        rec =
          start_supervised!(
            {PresenceRecorder,
             camera_id: id,
             resolve_policy: fn _camera_id -> {camera, @policy} end,
             start_extractor: fn _camera, _event -> exit(:noproc) end,
             finalize_extractor: fn _pid, _event -> :ok end},
            id: :exiting_extractor_recorder
          )

        state = :sys.get_state(rec)
        assert Process.alive?(rec)
        assert state.event == nil
        # the label is present, so the next transition opens from it
        assert state.present_labels == MapSet.new([{nil, "person"}])
      end)

    assert log =~ "could not start extractor"
  end

  # -- crash interactions -----------------------------------------------------

  # The aggregator's every-started-gets-a-cleared invariant reaches this lane:
  # its restart clears what its predecessor announced, and the recorder holding
  # an event open on that label closes it through the normal post window rather
  # than waiting out the cap for a scene the aggregator no longer knows about.
  test "an aggregator crash's owed cleared closes the event through the post window", ctx do
    id = ctx.camera_id
    rec = recorder(ctx)
    start_supervised!({PresenceAggregator, camera_id: id}, id: :aggregator)

    base = System.monotonic_time(:millisecond)
    PresenceAggregator.observed(id, base, %{{nil, "person"} => 0.6})
    PresenceAggregator.observed(id, base + 500, %{{nil, "person"} => 0.9})

    assert_receive {:extractor_started, %Event{id: eid}, ex_pid}
    aggregator = Registry.whereis(id, :presence)
    assert [{nil, "person", _at, _score}] = PresenceLedger.leftovers(id)

    Process.exit(aggregator, :kill)

    assert_receive {:presence_cleared, %PresenceEvent{camera_id: ^id, label: "person"}}, 2_000
    assert await_post_armed(rec)
    refute_received {:event_ended, %Event{camera_id: ^id}}

    fire(rec, :post_window, eid)
    assert_receive {:event_ended, %Event{id: ^eid, status: :finalized}}
    assert_receive {:extractor_finalized, ^ex_pid, %Event{id: ^eid}}
  end

  # `Cairn.PresenceSupervisor` holds only the two tables now: the lane workers
  # are children of their own cameras' trees, so a ledger crash restarts none
  # of them and cannot strand a clip. What survives is what matters — the
  # recorder that owns the open event, and the checkpoint row one child earlier
  # in the `:rest_for_one` order.
  #
  # Kills a process the whole application shares, so it is safe only in a
  # non-async suite.
  test "a ledger crash leaves the camera's recorder and its open clip alone", ctx do
    id = ctx.camera_id
    rec = recorder(ctx)

    announce(ctx, "person")
    started(ctx)
    assert_receive {:extractor_started, %Event{id: eid}, ex_pid}

    ledger = Process.whereis(Cairn.PresenceLedger)
    ref = Process.monitor(ledger)
    Process.exit(ledger, :kill)
    assert_receive {:DOWN, ^ref, :process, ^ledger, _reason}
    assert await_new_ledger(ledger)

    assert Registry.whereis(id, :presence_recorder) == rec
    assert Process.alive?(rec)

    state = :sys.get_state(rec)
    assert state.event.id == eid
    assert state.extractor == ex_pid
    assert {%Event{id: ^eid}, [{nil, "person"}], ^ex_pid, _slots} = PresenceCheckpoint.get(id)
  end

  # What `Cairn.Camera.Lane`'s child order buys, and the only place it shows:
  # a whole-lane start, no live batches, an event checkpointed against keys the
  # ledger still announces. The recorder starts first, so it restores those
  # keys as present, and the aggregator's `init/1` clear — which deletes the
  # same ledger rows — lands in a live mailbox and starts the close clock. The
  # event ends at its post window.
  #
  # Started the other way round the clear reaches nobody, and the row this
  # process restores from names keys the ledger no longer holds: they are
  # dropped as ghosts (`still_announced/2`), which arms the same clock by
  # another door — so what the order really decides is `adopt_announced/1`,
  # pinned by the test below it.
  test "a whole-lane start closes a restored event at its post window", ctx do
    id = ctx.camera_id
    extractor = relay(self())
    event = event(ctx)
    eid = event.id
    announce(ctx, "person")
    PresenceCheckpoint.put!(id, event, [{nil, "person"}], extractor)

    rec = start_lane(ctx)

    state = :sys.get_state(rec)
    assert state.event.id == eid
    assert state.present_labels == MapSet.new()
    assert state.post_token != nil

    fire(rec, :post_window, eid)
    assert_receive {:event_ended, %Event{id: ^eid, status: :finalized}}
    assert_receive {:extractor_finalized, ^extractor, %Event{id: ^eid}}
  end

  # The order's real consequence. An announced key with no checkpoint is a
  # `presence_started` the recorder was down for, and nothing will mention it
  # again — a key the aggregator holds as present never confirms twice. Only
  # `adopt_announced/1` can open its clip, and only if it reads the ledger
  # before the aggregator's `init/1` deletes those rows. Started second, the
  # recorder finds an empty ledger and the whole stay goes unrecorded.
  test "a whole-lane start records a presence announced while the lane was down", ctx do
    id = ctx.camera_id
    PresenceLedger.announced(id, nil, "person", DateTime.add(DateTime.utc_now(), -20), 0.9)

    rec = start_lane(ctx)

    assert_receive {:extractor_started, %Event{id: eid, max_scores: %{"person" => 0.9}}, _pid}
    assert_receive {:event_started, %Event{id: ^eid}}
    # and the aggregator's own clear, which followed, closed it through the
    # post window rather than leaving it to the cap
    assert :sys.get_state(rec).post_token != nil
    assert PresenceLedger.leftovers(id) == []
  end

  # The orphaned-finalize contract, with a REAL extractor: the recorder casts
  # the finalize from `terminate/2` and returns without awaiting it, and the
  # extractor — `:temporary` under `Cairn.EventSupervisor`, outside the camera's
  # tree — runs its close to `:finalized` on its own.
  test "a stopped recorder's extractor finalizes itself, with nobody waiting", ctx do
    id = ctx.camera_id
    test_pid = self()

    dir = Path.join(System.tmp_dir!(), "cairn_orphan_#{System.unique_integer([:positive])}")
    Cairn.DataDir.ensure!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    # The clip's own config: remux off, so the close is the write and nothing
    # else — this is about who casts the finalize, not what a remux costs. What
    # that leaves unproven is the slow variant: `Cairn.ClipRemux` allows 60 s
    # while `Cairn.EventSupervisor`'s children take the default 5 s shutdown, so
    # a finalize cast at NODE shutdown with remux on can still be killed
    # mid-remux and leave an `:active` row for boot reconciliation. Nothing in
    # this PR changed that bound; it only made the path reachable at shutdown.
    config = %Cairn.Config{data_dir: dir, remux_clips: false}
    start_supervised!({Cairn.RingBuffer, camera_id: id, pre_window_seconds: 60}, id: :ring)
    fill_ring(id)

    rec =
      start_supervised!(
        {
          PresenceRecorder,
          # the real seams: an extractor under `Cairn.EventSupervisor`, and the
          # default `Cairn.EventExtractor.finalize/2` as the close
          camera_id: id,
          resolve_policy: fn _camera_id -> {ctx.camera, @policy} end,
          start_extractor: fn camera, event ->
            result = Cairn.EventExtractor.start(camera, event, identity: :label, config: config)
            send(test_pid, {:started_real, event, result})
            result
          end
        },
        id: :orphan_recorder
      )

    started(ctx)
    assert_receive {:started_real, %Event{id: eid}, {:ok, extractor}}
    ref = Process.monitor(extractor)
    rec_ref = Process.monitor(rec)

    :ok = stop_supervised(:orphan_recorder)

    assert_receive {:DOWN, ^rec_ref, :process, ^rec, _shutdown}
    assert_receive {:event_ended, %Event{id: ^eid, status: :finalized}}
    # the extractor outlived the recorder and closed itself
    assert_receive {:DOWN, ^ref, :process, ^extractor, :normal}, 5_000
    assert Events.get(eid).status == :finalized
  end

  # Real media in the ring, so the clip the extractor closes has something in
  # it: a clip with no media closes `:partial` by the extractor's own rule,
  # which would say nothing about who finalized it.
  defp fill_ring(camera_id) do
    {_demuxer, events} =
      Cairn.MP4.Demuxer.push(
        Cairn.MP4.Demuxer.new(camera_id),
        File.read!("test/support/fixtures/media/testsrc.fmp4")
      )

    [{:init, init} | fragments] = events

    Cairn.RingBuffer.put_init(
      camera_id,
      init.data,
      init.codec,
      init.timescale,
      Cairn.ULID.generate()
    )

    for {:fragment, fragment} <- fragments,
        do: Cairn.RingBuffer.put_fragment(camera_id, fragment)
  end

  # A tier-1 lane starting whole, in `Cairn.Camera.Lane`'s order and with its
  # `:one_for_one` semantics: the recorder, then the aggregator. Returns the
  # recorder, drained of the aggregator's `init/1` casts — the aggregator's own
  # `:sys.get_state/1` proves they were sent, the recorder's that they landed.
  defp start_lane(ctx) do
    rec = recorder(ctx)
    agg = start_supervised!({PresenceAggregator, camera_id: ctx.camera_id}, id: :aggregator)
    _ = :sys.get_state(agg)
    _ = :sys.get_state(rec)
    rec
  end

  defp await_post_armed(recorder, attempts \\ 100),
    do: await_state(recorder, &(&1.post_token != nil), attempts, "close clock never started")

  defp await_cleared_event(recorder, attempts \\ 100),
    do: await_state(recorder, &(&1.event == nil), attempts, "never let go of its event")

  # The transition being waited on is delivered by a cast from a third process,
  # so the recorder's own `:sys.get_state/1` is a barrier for nothing here.
  defp await_state(recorder, ready?, attempts, what) do
    cond do
      ready?.(:sys.get_state(recorder)) ->
        true

      attempts > 0 ->
        Process.sleep(10)
        await_state(recorder, ready?, attempts - 1, what)

      true ->
        flunk("the recorder #{what}")
    end
  end

  defp await_new_ledger(dead, attempts \\ 200) do
    case Process.whereis(Cairn.PresenceLedger) do
      pid when is_pid(pid) and pid != dead ->
        true

      _absent when attempts > 0 ->
        Process.sleep(10)
        await_new_ledger(dead, attempts - 1)

      _absent ->
        flunk("the presence ledger never came back")
    end
  end
end
