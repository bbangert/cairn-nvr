defmodule Cairn.Pipeline.ReconnectIntegrationTest do
  @moduledoc """
  Phase-1 acceptance, end to end through the real `Cairn.Pipeline.Camera` under
  its real `Cairn.PipelineOwner`: a session boundary costs the pipeline and
  every long-lived element nothing, cuts the tracker element's live set in band
  (phase 2 moved the tracking there; the epoch announcement no longer does it),
  cannot let an observation of the session that ended reach the next one's
  event lifecycle, and never announces the stream as stopped.

  The boundary is driven on the bridge ingest, the one whose session lifecycle
  a test owns outright: `Cairn.Pipeline.BridgeSource` registers itself in
  `Cairn.Registry`, so a session's media and the `StreamClosed` that ends it
  are two messages this process sends — no OS process, no wall-clock waits, no
  camera. The rtsp ingest reaches the same in-band event from
  `Membrane.RTSPDualStream.Source`'s own reconnect ladder, which
  `Membrane.RTSPDualStream.SourceTest` drives against a mock client; the
  pipeline builds that element with its real client module and exposes no seam
  to replace it, so nothing here can reach it without a camera on the network.
  """

  use Cairn.DataCase, async: false

  alias Cairn.Config.Camera

  alias Cairn.{
    CameraTracker,
    Config,
    Event,
    Fragment,
    PipelineOwner,
    RingBuffer,
    RTPHub,
    StreamEpochs,
    Track
  }

  alias Cairn.Pipeline.ObservationStamper
  alias Cairn.TrackerDriver
  alias Membrane.Buffer
  alias Membrane.Testing.Pipeline, as: TestingPipeline

  @ts Path.absname("test/support/fixtures/media/testsrc.ts")

  # 6 s of 10 fps video, keyframe every second from pts 1.4 s: the CMAF muxer's
  # 2 s floor cuts it into two full segments and a 1.9 s tail it holds.
  @full_segments 2

  @policy %{pre: 5, post: 10, max: 300, max_unseen_ms: 3_000, max_live_tracks: 128}
  @box [0.1, 0.1, 0.2, 0.4]
  # No overlap with @box, so nothing the adoption floor could take for it.
  @far_box [0.6, 0.1, 0.2, 0.4]
  # …and no overlap with either, for a batch that has to mint rather than adopt
  # whatever the two above left suspended.
  @third_box [0.6, 0.55, 0.2, 0.4]

  describe "a session boundary" do
    @tag :capture_log
    test "keeps the pipeline and every long-lived child alive" do
      id = uid("keep")

      %{owner: owner, pipeline: pipeline, source: source} =
        start_camera(id, plugin: {:group, "g"})

      # The whole long-lived half, including the detect branch: the decoder's
      # and inference's native state is exactly what a reconnect must not cost,
      # and so — since phase 2 — are the tracker element's live tracks.
      long_lived = [
        :source,
        :tagger,
        :tee,
        :record_cut,
        :rtp_cut,
        :picker,
        :decoder,
        :infer,
        :stamper,
        :tracker,
        :track_sink
      ]

      before = Map.new(long_lived, &{&1, child_pid(pipeline, &1)})

      session(source, short_media())
      assert_receive {:stream_epoch, ^id, first, :started}, 10_000

      send(source, {:bridge_session_closed, :closed})
      session(source, short_media())
      assert_receive {:stream_epoch, ^id, second, :source_lost}, 10_000
      assert first != second

      assert :sys.get_state(owner).pipeline == pipeline
      assert Process.alive?(pipeline)
      assert Map.new(long_lived, &{&1, child_pid(pipeline, &1)}) == before

      # The positive control that makes the pids above evidence rather than a
      # graph that never noticed the boundary: the per-session branches behind
      # the gates were rebuilt, session 0 dropped once its tail had drained.
      for child <- [{:ring_sink, 1}, {:rtp_out, 1}],
          do: assert(is_pid(await_child(pipeline, child)))

      for child <- [{:ring_sink, 0}, {:rtp_out, 0}], do: await_child_gone(pipeline, child)
    end

    @tag :capture_log
    test "re-inits the ring under the new epoch, tail first, without restarting seq" do
      id = uid("ring")
      %{source: source} = start_camera(id)
      Phoenix.PubSub.subscribe(Cairn.PubSub, RingBuffer.topic(id))

      session(source, media())
      assert_receive {:stream_epoch, ^id, first, :started}, 10_000
      assert {[], %{epoch: ^first}} = ring_until_init()

      # The clip's two whole segments, which is everything the ring can hold
      # while the session is alive: the muxer holds its sub-2 s tail for an EOS.
      # Waited for rather than raced with, because that is where a live camera
      # stands when its session ends — a branch a burst has left seconds behind
      # would still be writing session 1 while session 2 re-inits over it.
      for seq <- 0..(@full_segments - 1) do
        assert_receive {:fragment, %Fragment{seq: ^seq, keyframe?: true}}, 10_000
      end

      # The cut and the next session's media with nothing waited for between
      # them: the tail flush is only a guarantee if it wins this race.
      send(source, {:bridge_session_closed, :closed})
      session(source, media())

      assert_receive {:stream_epoch, ^id, second, :source_lost}, 10_000
      assert {recorded, %{epoch: ^second}} = ring_until_init()

      # In ring order: what the EOS flushed out of the muxer reached the ring
      # before the new session re-initialised it. Without that flush the tail —
      # the last 1.9 s of the clip — is simply lost, and this is 0 fragments.
      assert [%Fragment{seq: 2, keyframe?: true}] = recorded

      # HLS keys its media sequence off `seq`, so the ring re-stamps across an
      # init rather than restarting: the next fragment is 3, not 0.
      assert_receive {:fragment, %Fragment{seq: 3}}, 10_000

      # …and the ring kept nothing of the session that ended.
      {:ok, %{fragments: held}} = RingBuffer.fetch_recent(id, 1_000)
      assert held != []
      assert Enum.all?(held, &(&1.seq >= 3))
    end
  end

  describe "the tracker" do
    @tag :capture_log
    test "sees the in-band epoch change: the object that comes back is itself" do
      id = uid("adopt")
      %{camera: camera, source: source} = start_camera(id)
      tracker = start_tracker(id)
      telemetry(id)
      Event.subscribe()

      session(source, short_media())
      assert_receive {:stream_epoch, ^id, first, :started}, 10_000
      await_tracker_epoch(tracker, first)

      sink = detect(sink(camera, tracker), first, @box, 90_000)
      assert_receive {:track_started, %Track{object_id: oid, epoch: ^first}}, 2_000

      send(source, {:bridge_session_closed, :closed})
      session(source, short_media())
      assert_receive {:stream_epoch, ^id, second, :source_lost}, 10_000
      await_tracker_epoch(tracker, second)

      # The announcement alone cuts nothing: the tracker element crosses the
      # boundary in band, on the first buffer that carries the new epoch, so
      # until one arrives the track is still live and still this session's.
      assert [%Track{object_id: ^oid}] = TrackerDriver.live_tracks(id)
      assert TrackerDriver.suspended_tracks(id) == []

      # That buffer does both halves at once, in one batch, which is the shape
      # production has: the live set is suspended before this batch's own
      # objects are tracked, and then the same box — on the far side of a
      # reconnect that took no time at all — adopts out of it rather than
      # arriving as something new.
      _sink = detect(sink, second, @box, 180_000)

      assert_receive {:telemetry, [:cairn, :tracker, :stream_reset], %{suspended: 1, ended: 0},
                      %{camera_id: ^id, reason: :source_lost}},
                     2_000

      assert_receive {:telemetry, [:cairn, :tracker, :adopted], %{count: 1}, %{camera_id: ^id}},
                     2_000

      assert_receive {:track_updated, %Track{object_id: ^oid, epoch: ^second}}, 2_000
      refute_received {:track_started, _}

      assert [%Track{object_id: ^oid}] = TrackerDriver.live_tracks(id)
      assert TrackerDriver.suspended_tracks(id) == []
    end

    @tag :capture_log
    test "drops an observation of the session that ended, drained after the boundary" do
      id = uid("stale")
      %{camera: camera, source: source} = start_camera(id)
      tracker = start_tracker(id)
      Event.subscribe()

      session(source, short_media())
      assert_receive {:stream_epoch, ^id, first, :started}, 10_000
      await_tracker_epoch(tracker, first)

      sink = detect(sink(camera, tracker), first, @box, 90_000)
      assert_receive {:track_started, %Track{object_id: oid, epoch: ^first}}, 2_000

      send(source, {:bridge_session_closed, :closed})
      session(source, short_media())
      assert_receive {:stream_epoch, ^id, second, :source_lost}, 10_000
      await_tracker_epoch(tracker, second)

      # The drain D8 exists for: a Detections buffer produced under the old
      # epoch, dispatched after the new one was minted. Elements survive the
      # boundary now, so this batch is not hypothetical.
      sink = detect(sink, first, @far_box, 180_000)
      _ = :sys.get_state(tracker)

      # Nothing of it reached the event lifecycle: no summary was broadcast and
      # no event moved. The tracker element did see it — it precedes the
      # boundary in the branch's own order, which is what makes it the tail of
      # the old session rather than a stray — and the identity it minted for
      # that box is one this process was never told about.
      refute_received {:track_started, _}
      refute_received {:track_updated, _}

      # The control: a box under the epoch now being decoded is taken, so what
      # dropped the first one was its tag and nothing else. A third box, not
      # the drained one, because that one now has an identity in the element
      # that the boundary would let it adopt.
      _sink = detect(sink, second, @third_box, 270_000)
      assert_receive {:track_started, %Track{object_id: other, epoch: ^second}}, 2_000
      refute other == oid
    end
  end

  describe "a pipeline rebuild" do
    @tag :capture_log
    test "takes the tracker element's tracks and leaves the event to finalize" do
      id = uid("rebuild")

      %{camera: camera, owner: owner, pipeline: pipeline, source: source} =
        start_camera(id, plugin: {:group, "g"})

      tracker = start_tracker(id)
      Event.subscribe()

      session(source, short_media())
      assert_receive {:stream_epoch, ^id, epoch, :started}, 10_000
      await_tracker_epoch(tracker, epoch)

      element = await_child(pipeline, :tracker)

      # A live track behind an open event — the state a rebuild is expensive
      # for, split across the two processes that hold it.
      _sink = detect(sink(camera, tracker), epoch, @box, 90_000)
      assert_receive {:track_started, %Track{object_id: oid, epoch: ^epoch}}, 2_000
      assert_receive {:event_started, %Event{id: eid}}, 2_000
      assert [%Track{object_id: ^oid}] = TrackerDriver.live_tracks(id)

      # The watchdog's escalation, driven rather than waited out: the detect
      # branch last produced a buffer two stall windows ago while the ring is
      # younger than one, and the tick that reads that is this process's.
      send(owner, {:stats, %{last_buffer_at_ms: System.monotonic_time(:millisecond) - 60_000}})
      send(owner, :watchdog)

      rebuilt = await_pipeline(owner, pipeline)
      assert rebuilt != pipeline

      # The tracks went with the element, because the element is a child of the
      # pipeline that was torn down. Nothing handed them over and nothing was
      # meant to: the driver's stand-in is dropped here for the same reason.
      await_dead(element)
      TrackerDriver.reset(id)

      # …and the pipeline that replaced it starts from nothing. Read off the
      # element's own state because neither a pad nor a notification exposes the
      # core, and a rebuild that ever grew a handoff would pass every other
      # assertion in this file.
      fresh = :sys.get_state(await_child(rebuilt, :tracker)).internal_state
      assert %{epoch: nil, processed: 0} = fresh
      assert Cairn.Tracker.live_tracks(fresh.core) == []
      assert Cairn.Tracker.suspended_tracks(fresh.core) == []

      # The finals went with them, which is the documented gap: this process
      # never crashed, so no checkpoint restore runs and nobody owes `oid` a
      # summary — its row closes at the next boot (`Cairn.Tracks.close_live/0`).
      refute_received {:track_ended, _}

      # What the rebuild must not cost is the event. The camera tracker outlives
      # the pipeline, so the post window it is already holding is what closes
      # it, with no further evidence and no tracker element to produce any.
      send(tracker, {:post_window, eid, :sys.get_state(tracker).post_token})
      assert_receive {:event_ended, %Event{id: ^eid, ended_at: ended_at}}, 2_000
      assert ended_at != nil
    end
  end

  describe ":camera_stopped" do
    @tag :capture_log
    test "is not what a reconnect mints" do
      id = uid("stop_boundary")
      %{source: source} = start_camera(id)

      session(source, short_media())
      assert_receive {:stream_epoch, ^id, _first, :started}, 10_000

      send(source, {:bridge_session_closed, :closed})
      session(source, short_media())
      assert_receive {:stream_epoch, ^id, _second, :source_lost}, 10_000

      refute_received {:stream_epoch, ^id, _epoch, :camera_stopped}
    end

    @tag :capture_log
    test "is not what a pipeline crash mints: the rebuild announces :source_lost" do
      id = uid("stop_crash")
      %{owner: owner, pipeline: pipeline, source: source} = start_camera(id)

      session(source, short_media())
      assert_receive {:stream_epoch, ^id, first, :started}, 10_000

      Process.exit(pipeline, :kill)
      rebuilt = await_pipeline(owner, pipeline)
      assert rebuilt != pipeline

      # The rebuilt pipeline's own source: the epoch is minted in band, so it
      # takes media to announce one.
      session(await_source(id, source), short_media())
      assert_receive {:stream_epoch, ^id, second, :source_lost}, 10_000
      assert second != first

      refute_received {:stream_epoch, ^id, _epoch, :camera_stopped}
    end

    @tag :capture_log
    test "is minted exactly once by a deliberate stop of the owner" do
      id = uid("stop_stop")
      %{source: source} = start_camera(id)

      session(source, short_media())
      assert_receive {:stream_epoch, ^id, _first, :started}, 10_000

      stop_supervised!({:owner, id})

      assert_receive {:stream_epoch, ^id, _epoch, :camera_stopped}, 10_000
      refute_receive {:stream_epoch, ^id, _epoch, :camera_stopped}, 300
    end
  end

  # -- the camera under test ----------------------------------------------------

  defp uid(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  defp config, do: %Config{data_dir: "tmp/reconnect_integration", stall_seconds: 30}

  defp start_camera(id, camera_opts \\ []) do
    camera =
      struct!(
        %Camera{id: id, rtsp_url: "rtsp://127.0.0.1:554/x", min_score: %{"default" => 0.5}},
        camera_opts
      )

    start_supervised!({RingBuffer, camera_id: id, pre_window_seconds: 120}, id: {:ring, id})
    start_supervised!({RTPHub, camera_id: id}, id: {:hub, id})

    # Before the owner: the first mint rides the first buffer, and this process
    # is the reference for every boundary asserted below.
    StreamEpochs.subscribe()

    owner =
      start_supervised!(
        {
          PipelineOwner,
          # Every boundary in this file is driven; a watchdog rebuild is what
          # these tests assert the absence of, so it is kept out of the way
          # rather than raced with.
          camera: camera,
          config: config(),
          backoff_min_ms: 20,
          backoff_max_ms: 100,
          watchdog_interval_ms: 60_000,
          flush_grace_ms: 100,
          status_fun: fn _id, _status -> :ok end
        },
        id: {:owner, id}
      )

    %{
      camera: camera,
      owner: owner,
      pipeline: await_pipeline(owner),
      source: await_source(id)
    }
  end

  defp media, do: File.read!(@ts)

  # Half the clip: enough for the demuxer to reach a keyframe and the tagger to
  # mint, and half the work for every test that only needs a boundary. Cut on a
  # whole number of 188-byte transport packets — the demuxer outlives sessions,
  # so a half packet left at the end of one desynchronises it for good and the
  # next session never produces a buffer to mint on.
  defp short_media, do: binary_part(media(), 0, 188 * 320)

  # One session's media, as `Cairn.FFmpegPort` delivers it: the whole thing is
  # in the element's mailbox ahead of whatever ends the session, which is what
  # makes the cut land after the media rather than in it.
  defp session(source, data), do: send(source, {:ts_data, data})

  defp await_pipeline(owner, previous \\ nil, attempts \\ 300) do
    case :sys.get_state(owner).pipeline do
      pid when is_pid(pid) and pid != previous ->
        pid

      _ when attempts > 0 ->
        Process.sleep(10)
        await_pipeline(owner, previous, attempts - 1)

      _ ->
        flunk("no pipeline for #{inspect(owner)} other than #{inspect(previous)}")
    end
  end

  defp await_source(camera_id, previous \\ nil, attempts \\ 300) do
    case Cairn.Registry.whereis(camera_id, :bridge_source) do
      pid when is_pid(pid) and pid != previous ->
        pid

      _ when attempts > 0 ->
        Process.sleep(10)
        await_source(camera_id, previous, attempts - 1)

      _ ->
        flunk("no bridge source for #{camera_id} other than #{inspect(previous)}")
    end
  end

  # `Membrane.Testing.Pipeline.get_child_pid!/2` is a plain call every pipeline
  # answers, testing or not.
  defp child_pid(pipeline, child), do: TestingPipeline.get_child_pid!(pipeline, child)

  defp await_child(pipeline, child, attempts \\ 300) do
    case TestingPipeline.get_child_pid(pipeline, child) do
      {:ok, pid} ->
        pid

      {:error, _reason} when attempts > 0 ->
        Process.sleep(10)
        await_child(pipeline, child, attempts - 1)

      {:error, reason} ->
        flunk("#{inspect(child)} never appeared: #{inspect(reason)}")
    end
  end

  defp await_child_gone(pipeline, child, attempts \\ 300) do
    case TestingPipeline.get_child_pid(pipeline, child) do
      {:error, _gone} ->
        :ok

      {:ok, _pid} when attempts > 0 ->
        Process.sleep(10)
        await_child_gone(pipeline, child, attempts - 1)

      {:ok, pid} ->
        flunk("#{inspect(child)} is still there as #{inspect(pid)}")
    end
  end

  defp await_dead(pid, attempts \\ 300) do
    cond do
      not Process.alive?(pid) -> :ok
      attempts > 0 -> Process.sleep(10) && await_dead(pid, attempts - 1)
      true -> flunk("#{inspect(pid)} outlived the pipeline that owned it")
    end
  end

  # -- the ring's broadcasts ----------------------------------------------------

  # Fragments and inits in the order the ring published them — a mailbox scan
  # per pattern would find a later init before an earlier fragment and prove
  # nothing about which reached the ring first.
  defp ring_until_init(acc \\ []) do
    assert_receive {tag, payload} when tag in [:init_segment, :fragment], 10_000

    case tag do
      :init_segment -> {Enum.reverse(acc), payload}
      :fragment -> ring_until_init([payload | acc])
    end
  end

  # -- the tracker and the detect branch's sink ---------------------------------

  defp start_tracker(camera_id) do
    on_exit(fn -> Cairn.EventCheckpoint.delete(camera_id) end)

    start_supervised!(
      {
        CameraTracker,
        # Unregistered: the sink is handed this pid, so nothing here depends on
        # the pool's naming. The clip pipeline is another test's business.
        camera_id: camera_id,
        name: nil,
        start_extractor: fn _camera, _event ->
          {:ok, spawn(fn -> Process.sleep(:infinity) end)}
        end,
        finalize_extractor: fn _pid, _event -> :ok end
      },
      id: {:tracker, camera_id}
    )
  end

  # The real head of the detect branch's cairn-side half, driven at its input
  # pad: the epoch it tags observations with comes from the buffer, which is
  # the whole point of D8 and what the staleness test turns on. Its batches go
  # on through the real tracker element and the real sink
  # (`Cairn.TrackerDriver`), so the only thing skipped between the NIF and the
  # camera tracker is the NIF.
  defp sink(camera, tracker) do
    {[], state} =
      ObservationStamper.handle_init(
        %{},
        struct(ObservationStamper, camera: camera, policy: @policy)
      )

    %{stamper: state, camera: camera, tracker: tracker}
  end

  defp detect(%{stamper: stamper} = sink, epoch, bbox, pts) do
    buffer = %Buffer{
      payload: <<>>,
      pts: pts,
      metadata: %{observations: [frame(bbox, pts)], stream_epoch: epoch}
    }

    {actions, stamper} = ObservationStamper.handle_buffer(:input, buffer, %{}, stamper)

    for {:buffer, {:output, batch}} <- actions do
      TrackerDriver.batch(sink.tracker, sink.camera, @policy, batch)
    end

    %{sink | stamper: stamper}
  end

  # One frame of `Cairn.Pipeline.Inference`'s observation shape, carrying a
  # person the tracker's default floors accept.
  defp frame(bbox, pts) do
    %{
      pts: pts,
      observed_at_ms: System.os_time(:millisecond),
      inferred: true,
      infer_us: 12_000,
      objects: [
        %{label: "person", score: 0.9, bbox: bbox, track_id: nil, observation_kind: "detected"}
      ]
    }
  end

  # The tracker applies an epoch broadcast on its own timeline; every assertion
  # about what the boundary did to it has to stand behind this.
  defp await_tracker_epoch(tracker, epoch, attempts \\ 300) do
    case :sys.get_state(tracker).current_epoch do
      ^epoch ->
        :ok

      _other when attempts > 0 ->
        Process.sleep(10)
        await_tracker_epoch(tracker, epoch, attempts - 1)

      other ->
        flunk("tracker never applied epoch #{epoch} (holds #{inspect(other)})")
    end
  end

  # The suspend/adopt path's public report. `Logger.info` is emitted beside it
  # and this env runs the logger at :warning, so telemetry is what a test can
  # read.
  defp telemetry(camera_id) do
    test = self()
    handler = "reconnect-#{camera_id}"

    :telemetry.attach_many(
      handler,
      [[:cairn, :tracker, :stream_reset], [:cairn, :tracker, :adopted]],
      fn event, measurements, meta, _config ->
        send(test, {:telemetry, event, measurements, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end
end
