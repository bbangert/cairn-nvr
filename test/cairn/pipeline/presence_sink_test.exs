defmodule Cairn.Pipeline.PresenceSinkTest do
  use ExUnit.Case, async: true

  alias Cairn.{CameraControl, Event, PresenceEvent}
  alias Cairn.Config.Camera
  alias Cairn.NativeStub
  alias Cairn.Pipeline.PresenceSink
  alias Cairn.PresenceFixtures
  alias Membrane.Buffer

  @box [0.1, 0.1, 0.2, 0.2]

  # Two disjoint zones with a gap between them and a third nested inside the
  # first, so a box can land in one, in two, or in none — `hits/2` reads the
  # box's bottom centre, which is what the `@in_*` boxes below are named for.
  @drive %{id: "drive", name: "Drive", points: [[0.0, 0.0], [0.45, 0.0], [0.45, 0.9], [0.0, 0.9]]}
  @porch %{id: "porch", name: "Porch", points: [[0.55, 0.0], [1.0, 0.0], [1.0, 0.9], [0.55, 0.9]]}
  @yard %{id: "yard", name: "Yard", points: [[0.1, 0.1], [0.4, 0.1], [0.4, 0.5], [0.1, 0.5]]}

  # foot (0.2, 0.8) — inside drive, below yard
  @in_drive [0.1, 0.6, 0.2, 0.2]
  # foot (0.2, 0.3) — inside drive and the yard nested in it
  @in_both [0.1, 0.1, 0.2, 0.2]
  # foot (0.5, 0.95) — the gap between the zones, below both
  @outside [0.4, 0.75, 0.2, 0.2]

  setup do
    camera_id = "psink_#{System.unique_integer([:positive])}"
    Event.subscribe()

    # A confirm here would otherwise open a real recording through the
    # `Cairn.PresenceRecorder` that starts beside the aggregator — this suite
    # feeds the sink, and what it asserts is what reaches presence state.
    CameraControl.set(camera_id, %{recording_enabled: false})

    # The sink's feeds start real aggregators in the application-wide
    # pool; retire them or every test leaks one for the suite's life.
    on_exit(fn ->
      Cairn.PresenceAggregator.retire(camera_id)
      Cairn.Registry.await_unregistered(camera_id, :presence)
      Cairn.Registry.await_unregistered(camera_id, :presence_recorder)
    end)

    %{
      camera_id: camera_id,
      camera: %Camera{id: camera_id, rtsp_url: "rtsp://h/1", min_score: %{"default" => 0.5}}
    }
  end

  defp sink(ctx) do
    {[], state} = PresenceSink.handle_init(%{}, struct(PresenceSink, camera: ctx.camera))
    state
  end

  defp feed(state, observations) do
    PresenceSink.handle_buffer(
      :input,
      %Buffer{payload: <<>>, metadata: %{observations: observations}},
      %{},
      state
    )
  end

  defp frame(objects), do: %{NativeStub.frame() | objects: objects}

  # `@box` rather than the fixtures' own default: it is only the zoneless
  # cases' box, and this suite's zones are drawn around these coordinates.
  defp object(label, score, kind \\ "detected"),
    do: PresenceFixtures.object(label, score, kind, @box)

  defp object(label, score, kind, bbox), do: PresenceFixtures.object(label, score, kind, bbox)

  defp zoneless(ctx), do: %{ctx | camera: %{ctx.camera | zones: []}}

  # The aggregator's `{zone, label}` state map, read through a `:sys.get_state`
  # barrier — `observed/3` is a cast, so nothing else orders it against the
  # assertion.
  defp present(camera_id) do
    camera_id |> Cairn.Registry.whereis(:presence) |> :sys.get_state() |> Map.fetch!(:present)
  end

  # Two buffers back to back — the aggregator counts sightings per call, so
  # even the same millisecond's clock reading confirms.
  defp two_beats(state, observations) do
    {[], state} = feed(state, observations)
    feed(state, observations)
  end

  test "detected objects above the floor forward per-label best scores, confirming after two buffers",
       ctx do
    id = ctx.camera_id
    state = sink(ctx)

    {[], state} = feed(state, [frame([object("person", 0.6)])])
    {[], _state} = feed(state, [frame([object("person", 0.9)])])

    assert_receive {:presence_started,
                    %PresenceEvent{camera_id: ^id, zone: nil, label: "person", score: 0.9}}
  end

  test "objects below the camera's floor, and tracked-kind objects, are not evidence", ctx do
    id = ctx.camera_id
    state = sink(ctx)
    below_floor = object("person", 0.2)
    tracked = object("car", 0.9, "tracked")

    {actions, _state} = two_beats(state, [frame([below_floor, tracked])])
    assert actions == []

    refute_receive {:presence_started, %PresenceEvent{camera_id: ^id}}, 50
  end

  test "a runtime min_score override replaces the camera's configured floor", ctx do
    id = ctx.camera_id
    CameraControl.set(id, %{min_score: 0.95})
    on_exit(fn -> CameraControl.set(id, %{min_score: nil}) end)

    state = sink(ctx)
    # Clears the camera's configured 0.5 floor but not the 0.95 override.
    two_beats(state, [frame([object("person", 0.9)])])

    refute_receive {:presence_started, %PresenceEvent{camera_id: ^id}}, 50
  end

  test "detection_enabled false drops the batch and clears whatever was present", ctx do
    id = ctx.camera_id
    state = sink(ctx)
    {_actions, state} = two_beats(state, [frame([object("person", 0.9)])])
    assert_receive {:presence_started, %PresenceEvent{camera_id: ^id, label: "person"}}

    CameraControl.set(id, %{detection_enabled: false})
    on_exit(fn -> CameraControl.set(id, %{detection_enabled: true}) end)

    {actions, state} = feed(state, [frame([object("person", 0.9)])])
    assert actions == []
    assert state.dropped == 1

    assert_receive {:presence_cleared, %PresenceEvent{camera_id: ^id, zone: nil, label: "person"}}
  end

  test "a buffer without the observations key is counted-dropped, not crashed on, and the element keeps working",
       ctx do
    id = ctx.camera_id
    state = sink(ctx)

    {actions, state} =
      PresenceSink.handle_buffer(:input, %Buffer{payload: <<>>, metadata: %{}}, %{}, state)

    assert actions == []
    assert state.dropped == 1

    {_actions, _state} = two_beats(state, [frame([object("person", 0.9)])])
    assert_receive {:presence_started, %PresenceEvent{camera_id: ^id, label: "person"}}
  end

  test "a native-gate skip frame (inferred: false) is evidence of nothing", ctx do
    id = ctx.camera_id
    state = sink(ctx)

    {[], state} = feed(state, [frame([object("person", 0.9)])])
    {[], state} = feed(state, [frame([object("person", 0.9)])])
    assert_receive {:presence_started, %PresenceEvent{camera_id: ^id, label: "person"}}

    # The engine's replayed prediction under a closed native gate
    # (`Decision::Skip`): the model never looked, so no absence span may
    # open off this frame — the sibling of pipeline-gate silence.
    skip = %{NativeStub.frame(false) | objects: [object("person", 0.9, "tracked")]}
    {[], state} = feed(state, [skip])

    pid = Cairn.Registry.whereis(id, :presence)
    assert :sys.get_state(pid).present[{nil, "person"}].absent_since_ms == nil
    refute_receive {:presence_cleared, %PresenceEvent{camera_id: ^id}}, 50

    # …while the buffer still proves the branch alive to the watchdog.
    assert is_integer(state.last_buffer_at_ms)
  end

  describe "the live detections topic" do
    setup ctx do
      Cairn.LiveDetections.subscribe(ctx.camera_id)
      :ok
    end

    test "each inferred frame publishes its complete detection list", ctx do
      id = ctx.camera_id
      state = sink(ctx)

      {[], state} =
        feed(state, [frame([object("person", 0.9), object("car", 0.8)])])

      assert_receive {:detections, ^id, [%{label: "person"}, %{label: "car"}]}

      # A buffer carrying two frames publishes twice: the overlay's unit is a
      # frame, and the last one broadcast is what ends up on screen.
      {[], _state} = feed(state, [frame([object("person", 0.7)]), frame([])])

      assert_receive {:detections, ^id, [%{label: "person", score: 0.7}]}
      assert_receive {:detections, ^id, []}
    end

    test "a frame the model found nothing in publishes an empty list", ctx do
      id = ctx.camera_id

      {[], _state} = feed(sink(ctx), [frame([])])

      assert_receive {:detections, ^id, []}
    end

    test "a predictor's guess and a boxless detection are not published", ctx do
      id = ctx.camera_id

      boxless = Map.delete(object("person", 0.9), :bbox)
      {[], _state} = feed(sink(ctx), [frame([object("dog", 0.9, "tracked"), boxless])])

      assert_receive {:detections, ^id, []}
    end

    # The deliberate difference from the aggregator's fold: presence state and
    # the recording lane are gated on floors, the overlay is not. It shows
    # what the model saw, which is what an operator tuning a floor needs.
    test "a detection below the camera's floor is published anyway", ctx do
      id = ctx.camera_id

      {[], _state} = feed(sink(ctx), [frame([object("person", 0.2)])])

      assert_receive {:detections, ^id, [%{label: "person", score: 0.2}]}
      refute_receive {:presence_started, %PresenceEvent{camera_id: ^id}}, 50
    end

    # These refutes are immediate, unlike the `presence_*` ones elsewhere in
    # this file: `feed/2` runs `handle_buffer/4` in the test process and
    # `local_broadcast` sends from whoever calls it, so a message this buffer
    # was going to produce is already in the mailbox. The presence ones cross
    # a real boundary — `PresenceAggregator.observed/3` is a cast — and need
    # either a timeout or a `:sys.get_state` barrier.
    test "a native-gate skip frame publishes nothing at all", ctx do
      id = ctx.camera_id

      skip = %{NativeStub.frame(false) | objects: [object("person", 0.9)]}
      {[], _state} = feed(sink(ctx), [skip])

      # Not even an empty list: the model never looked, so the boxes already
      # on screen are the freshest thing anyone knows.
      refute_received {:detections, ^id, _}
    end

    # Without this the overlay has nothing to act on: it runs no staleness
    # timer, the video keeps playing, and the last boxes drawn would assert
    # themselves over a camera nobody is watching any more.
    test "switching detection off clears the overlay once, then stays quiet", ctx do
      id = ctx.camera_id
      state = sink(ctx)

      {[], state} = feed(state, [frame([object("person", 0.9)])])
      assert_received {:detections, ^id, [%{label: "person"}]}

      CameraControl.set(id, %{detection_enabled: false})
      on_exit(fn -> CameraControl.set(id, %{detection_enabled: true}) end)

      {[], state} = feed(state, [frame([object("person", 0.9)])])
      assert_received {:detections, ^id, []}

      # once per transition, like the aggregator's own notice — a disabled
      # camera must not pay a broadcast per buffer for the rest of its life
      {[], _state} = feed(state, [frame([object("person", 0.9)])])
      refute_received {:detections, ^id, _}
    end
  end

  test "the stats reply carries the liveness stamp the owner's watchdog reads", ctx do
    state = sink(ctx)

    # Before any buffer the stamp is honestly nil — the owner treats nil as
    # "nothing to judge yet", not as staleness.
    assert {[notify_parent: {:stats, %{last_buffer_at_ms: nil}}], state} =
             PresenceSink.handle_parent_notification(:stats, %{}, state)

    {[], state} = feed(state, [frame([object("person", 0.6)])])

    assert {[notify_parent: {:stats, stats}], _state} =
             PresenceSink.handle_parent_notification(:stats, %{}, state)

    assert is_integer(stats.last_buffer_at_ms)
    assert stats.forwarded == 1
  end

  describe "zones" do
    setup ctx do
      %{camera: %{ctx.camera | zones: [@drive, @porch, @yard]}}
    end

    test "a box standing in a zone is presence under that zone's id", ctx do
      id = ctx.camera_id

      two_beats(sink(ctx), [frame([object("person", 0.9, "detected", @in_drive)])])

      assert_receive {:presence_started,
                      %PresenceEvent{camera_id: ^id, zone: "drive", label: "person"}}
    end

    test "a box standing outside every zone is evidence of nothing", ctx do
      id = ctx.camera_id

      two_beats(sink(ctx), [frame([object("person", 0.9, "detected", @outside)])])

      refute_receive {:presence_started, %PresenceEvent{camera_id: ^id}}, 50
      # The aggregator was still called — with an empty map, which is the
      # absence evidence a zoned camera owes for the scene outside its zones.
      assert present(id) == %{}
    end

    test "a box standing in two overlapping zones owes each of them a state", ctx do
      id = ctx.camera_id

      two_beats(sink(ctx), [frame([object("person", 0.9, "detected", @in_both)])])

      assert_receive {:presence_started, %PresenceEvent{camera_id: ^id, zone: "drive"}}
      assert_receive {:presence_started, %PresenceEvent{camera_id: ^id, zone: "yard"}}
    end

    test "a camera with no zones reports the one whole-frame state", ctx do
      id = ctx.camera_id

      two_beats(sink(zoneless(ctx)), [frame([object("person", 0.9, "detected", @outside)])])

      assert_receive {:presence_started, %PresenceEvent{camera_id: ^id, zone: nil}}
      assert Map.keys(present(id)) == [{nil, "person"}]
    end

    # The recorder draws an event's trigger and its sidecar from these frames,
    # so an out-of-zone box reaching it would illustrate an event the
    # aggregator refused to open. `pending` is where a batch waits while no
    # event is open, and reading it is the barrier for the cast that sent it.
    test "the recorder is given the surviving objects only", ctx do
      state = sink(ctx)

      {[], _state} =
        feed(state, [
          frame([
            object("person", 0.9, "detected", @in_drive),
            object("car", 0.9, "detected", @outside)
          ])
        ])

      recorder = Cairn.Registry.whereis(ctx.camera_id, :presence_recorder)
      assert {_floors, [frame], _at_ms} = :sys.get_state(recorder).pending
      assert [%{label: "person", zones: ["drive"]}] = frame.objects
    end

    # The recorder wants a predicted box for the same reason it wants a
    # detected one — the sidecar and the trigger — and a zoned camera must not
    # be the thing that takes it away. `seen/2` is what keeps it out of
    # presence state.
    test "a tracked box inside a zone reaches the recorder but is not evidence", ctx do
      id = ctx.camera_id

      {[], _state} =
        two_beats(sink(ctx), [frame([object("person", 0.9, "tracked", @in_drive)])])

      recorder = Cairn.Registry.whereis(id, :presence_recorder)
      assert {_floors, [frame], _at_ms} = :sys.get_state(recorder).pending
      assert [%{label: "person", zones: ["drive"]}] = frame.objects

      assert present(id) == %{}
      refute_receive {:presence_started, %PresenceEvent{camera_id: ^id}}, 50
    end

    test "a tracked box outside every zone is dropped like any other", ctx do
      {[], _state} = feed(sink(ctx), [frame([object("person", 0.9, "tracked", @outside)])])

      recorder = Cairn.Registry.whereis(ctx.camera_id, :presence_recorder)
      assert {_floors, [frame], _at_ms} = :sys.get_state(recorder).pending
      assert frame.objects == []
    end

    test "the overlay is shown the boxes the zones reject", ctx do
      id = ctx.camera_id
      Cairn.LiveDetections.subscribe(id)

      {[], _state} =
        feed(sink(ctx), [
          frame([
            object("person", 0.9, "detected", @in_drive),
            object("car", 0.9, "detected", @outside)
          ])
        ])

      assert_receive {:detections, ^id, [%{label: "person"}, %{label: "car"}]}
    end

    test "removing a zone clears what was standing in it", ctx do
      id = ctx.camera_id

      {[], state} = two_beats(sink(ctx), [frame([object("person", 0.9, "detected", @in_drive)])])
      assert_receive {:presence_started, %PresenceEvent{camera_id: ^id, zone: "drive"}}
      assert Map.has_key?(present(id), {"drive", "person"})

      camera = %{ctx.camera | zones: [@porch]}

      assert {[], %{camera: ^camera}} =
               PresenceSink.handle_parent_notification({:policy, camera, %{}}, %{}, state)

      assert_receive {:presence_cleared,
                      %PresenceEvent{camera_id: ^id, zone: "drive", label: "person"}}
    end

    test "a camera gaining its first zone clears its whole-frame state", ctx do
      id = ctx.camera_id
      ctx = zoneless(ctx)

      {[], state} = two_beats(sink(ctx), [frame([object("person", 0.9, "detected", @in_drive)])])
      assert_receive {:presence_started, %PresenceEvent{camera_id: ^id, zone: nil}}
      assert Map.has_key?(present(id), {nil, "person"})

      camera = %{ctx.camera | zones: [@drive]}
      {[], _state} = PresenceSink.handle_parent_notification({:policy, camera, %{}}, %{}, state)

      assert_receive {:presence_cleared,
                      %PresenceEvent{camera_id: ^id, zone: nil, label: "person"}}
    end

    test "a zone reshaped in place clears what was standing in it", ctx do
      id = ctx.camera_id

      {[], state} = two_beats(sink(ctx), [frame([object("person", 0.9, "detected", @in_drive)])])
      assert_receive {:presence_started, %PresenceEvent{camera_id: ^id, zone: "drive"}}

      # The same id over a smaller outline: the standing state may sit outside
      # it, and nothing later would say so on a still scene.
      shrunk = %{@drive | points: [[0.0, 0.0], [0.2, 0.0], [0.2, 0.2], [0.0, 0.2]]}
      camera = %{ctx.camera | zones: [shrunk, @porch, @yard]}
      {[], _state} = PresenceSink.handle_parent_notification({:policy, camera, %{}}, %{}, state)

      assert_receive {:presence_cleared,
                      %PresenceEvent{camera_id: ^id, zone: "drive", label: "person"}}
    end

    test "a renamed zone keeps its states", ctx do
      id = ctx.camera_id

      {[], state} = two_beats(sink(ctx), [frame([object("person", 0.9, "detected", @in_drive)])])
      assert_receive {:presence_started, %PresenceEvent{camera_id: ^id, zone: "drive"}}

      camera = %{ctx.camera | zones: [%{@drive | name: "Front drive"}, @porch, @yard]}
      {[], _state} = PresenceSink.handle_parent_notification({:policy, camera, %{}}, %{}, state)

      refute_receive {:presence_cleared, %PresenceEvent{camera_id: ^id}}, 50
    end

    test "a reload that leaves the zones alone clears nothing", ctx do
      id = ctx.camera_id

      {[], state} = two_beats(sink(ctx), [frame([object("person", 0.9, "detected", @in_drive)])])
      assert_receive {:presence_started, %PresenceEvent{camera_id: ^id, zone: "drive"}}

      {[], _state} =
        PresenceSink.handle_parent_notification({:policy, ctx.camera, %{}}, %{}, state)

      refute_receive {:presence_cleared, %PresenceEvent{camera_id: ^id}}, 50
    end
  end
end
