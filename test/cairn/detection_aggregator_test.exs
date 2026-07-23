defmodule Cairn.DetectionAggregatorTest do
  use ExUnit.Case, async: false

  alias Cairn.{DetectionAggregator, Event, EventCheckpoint}
  alias Cairn.Config.Camera

  @windows %{pre: 5, post: 10, max: 300}

  setup do
    camera_id = "agg_#{System.unique_integer([:positive])}"
    camera = %Camera{id: camera_id, rtsp_url: "rtsp://h/1", min_score: %{"default" => 0.5}}
    test_pid = self()

    agg =
      start_supervised!(
        {DetectionAggregator,
         name: nil,
         start_extractor: fn _camera, event ->
           pid = spawn(fn -> Process.sleep(:infinity) end)
           send(test_pid, {:extractor_started, event, pid})
           {:ok, pid}
         end,
         finalize_extractor: fn pid, event ->
           send(test_pid, {:extractor_finalized, pid, event})
         end}
      )

    Event.subscribe()
    on_exit(fn -> EventCheckpoint.delete(camera_id) end)

    %{agg: agg, camera: camera, camera_id: camera_id}
  end

  defp detect(agg, camera, score \\ 0.9, bbox \\ [0.1, 0.1, 0.2, 0.4]) do
    DetectionAggregator.detections(agg, camera, @windows, 90_000, [
      %{label: "person", score: score, bbox: bbox}
    ])
  end

  defp token(agg, camera_id, kind), do: :sys.get_state(agg).cameras[camera_id][kind]

  defp fire(agg, kind, camera_id, event_id) do
    tk = token(agg, camera_id, if(kind == :post_window, do: :post_token, else: :max_token))
    send(agg, {kind, camera_id, event_id, tk})
  end

  test "detection starts an event with extractor and checkpoint", %{
    agg: agg,
    camera: camera,
    camera_id: id
  } do
    detect(agg, camera)

    assert_receive {:extractor_started, %Event{camera_id: ^id} = event, _pid}
    assert_receive {:event_started, %Event{id: eid, camera_id: ^id}}
    assert event.id == eid
    assert [%{label: "person", object_id: 1}] = event.labels
    assert event.max_scores == %{"person" => 0.9}

    assert [{^id, %Event{id: ^eid}}] =
             Enum.filter(EventCheckpoint.all(), fn {cid, _} -> cid == id end)
  end

  test "captures the highest-scoring detection as the snapshot trigger", %{
    agg: agg,
    camera: camera,
    camera_id: id
  } do
    detect(agg, camera, 0.6, [0.1, 0.1, 0.2, 0.4])
    assert_receive {:event_started, %Event{camera_id: ^id, trigger: t0}}
    assert %{label: "person", score: 0.6, bbox: [0.1, 0.1, 0.2, 0.4], t: +0.0} = t0

    # a stronger detection replaces the trigger, its bbox included
    detect(agg, camera, 0.92, [0.3, 0.2, 0.25, 0.5])
    assert_receive {:event_updated, %Event{trigger: %{score: 0.92, bbox: [0.3, 0.2, 0.25, 0.5]}}}

    # a weaker one does not
    detect(agg, camera, 0.7)
    assert_receive {:event_updated, %Event{trigger: %{score: 0.92}}}
  end

  test "below min_score never starts an event", %{agg: agg, camera: camera, camera_id: id} do
    detect(agg, camera, 0.3)
    refute_receive {:event_started, %Event{camera_id: ^id}}, 200
  end

  test "detections during an event merge and update", %{agg: agg, camera: camera, camera_id: id} do
    detect(agg, camera)
    assert_receive {:event_started, %Event{id: eid, camera_id: ^id}}

    detect(agg, camera, 0.95, [0.12, 0.1, 0.2, 0.4])
    assert_receive {:event_updated, %Event{id: ^eid} = event}
    refute_receive {:event_started, %Event{camera_id: ^id}}, 100

    assert length(event.labels) == 2
    assert event.max_scores == %{"person" => 0.95}
    # same physical object keeps its tracker id
    assert [%{object_id: oid}, %{object_id: oid}] = event.labels
  end

  test "post-window timeout finalizes", %{agg: agg, camera: camera, camera_id: id} do
    detect(agg, camera)
    assert_receive {:extractor_started, %Event{id: eid}, ex_pid}

    fire(agg, :post_window, id, eid)

    assert_receive {:extractor_finalized, ^ex_pid, %Event{id: ^eid, status: :finalized} = event}
    assert_receive {:event_ended, %Event{id: ^eid, status: :finalized}}
    assert %DateTime{} = event.ended_at
    assert Enum.filter(EventCheckpoint.all(), fn {cid, _} -> cid == id end) == []
  end

  test "max-cap finalizes and the next detection reopens", %{
    agg: agg,
    camera: camera,
    camera_id: id
  } do
    detect(agg, camera)
    assert_receive {:event_started, %Event{id: first}}

    fire(agg, :max_event, id, first)
    assert_receive {:event_ended, %Event{id: ^first}}

    detect(agg, camera)
    assert_receive {:event_started, %Event{id: second}}
    refute first == second
  end

  test "stale timer for an already-finalized event is ignored", %{
    agg: agg,
    camera: camera,
    camera_id: id
  } do
    detect(agg, camera)
    assert_receive {:event_started, %Event{id: eid}}

    old_token = token(agg, id, :post_token)
    fire(agg, :post_window, id, eid)
    assert_receive {:event_ended, %Event{id: ^eid}}

    send(agg, {:post_window, id, eid, old_token})
    refute_receive {:event_ended, _}, 100
  end

  test "an already-delivered timer message from before a reschedule cannot finalize", %{
    agg: agg,
    camera: camera,
    camera_id: id
  } do
    detect(agg, camera)
    assert_receive {:event_started, %Event{id: eid}}
    stale_token = token(agg, id, :post_token)

    # a new detection cancels + reschedules the post window; the stale
    # message may already be in the mailbox — its token no longer matches
    detect(agg, camera, 0.95, [0.12, 0.1, 0.2, 0.4])
    assert_receive {:event_updated, %Event{id: ^eid}}

    send(agg, {:post_window, id, eid, stale_token})
    refute_receive {:event_ended, _}, 100

    # the current token still finalizes
    fire(agg, :post_window, id, eid)
    assert_receive {:event_ended, %Event{id: ^eid, status: :finalized}}
  end

  test "extractor crash mid-event ends the event as partial", %{
    agg: agg,
    camera: camera,
    camera_id: id
  } do
    detect(agg, camera)
    assert_receive {:extractor_started, %Event{id: eid}, ex_pid}
    assert_receive {:event_started, _}

    Process.exit(ex_pid, :kill)

    assert_receive {:event_ended, %Event{id: ^eid, status: :partial}}
    assert Enum.filter(EventCheckpoint.all(), fn {cid, _} -> cid == id end) == []
  end

  test "orphaned checkpoint entries are ended as partial on restart", %{camera_id: id} do
    event = %Event{id: Ecto.UUID.generate(), camera_id: id, started_at: DateTime.utc_now()}
    EventCheckpoint.put(id, event)

    start_supervised!({DetectionAggregator, name: nil}, id: :agg_restore)

    eid = event.id
    assert_receive {:event_ended, %Event{id: ^eid, status: :partial}}
    assert Enum.filter(EventCheckpoint.all(), fn {cid, _} -> cid == id end) == []
  end

  test "restart re-attaches to a live extractor and can finalize it", %{camera_id: id} do
    test_pid = self()
    event = %Event{id: Ecto.UUID.generate(), camera_id: id, started_at: DateTime.utc_now()}

    extractor =
      spawn(fn ->
        Registry.register(Cairn.Registry, {id, {:extractor, event.id}}, nil)
        send(test_pid, :registered)
        Process.sleep(:infinity)
      end)

    assert_receive :registered
    EventCheckpoint.put(id, event)

    agg =
      start_supervised!(
        {DetectionAggregator,
         name: nil,
         finalize_extractor: fn pid, ev -> send(test_pid, {:extractor_finalized, pid, ev}) end},
        id: :agg_reattach
      )

    eid = event.id
    refute_receive {:event_ended, %Event{id: ^eid}}, 100

    fire(agg, :post_window, id, eid)
    assert_receive {:extractor_finalized, ^extractor, %Event{id: ^eid}}
    assert_receive {:event_ended, %Event{id: ^eid, status: :finalized}}
  end
end
