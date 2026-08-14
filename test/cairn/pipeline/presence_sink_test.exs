defmodule Cairn.Pipeline.PresenceSinkTest do
  use ExUnit.Case, async: true

  alias Cairn.{CameraControl, Event, PresenceEvent}
  alias Cairn.Config.Camera
  alias Cairn.NativeStub
  alias Cairn.Pipeline.PresenceSink
  alias Membrane.Buffer

  setup do
    camera_id = "psink_#{System.unique_integer([:positive])}"
    Event.subscribe()

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

  defp object(label, score, kind \\ "detected"),
    do: %{
      label: label,
      score: score,
      bbox: [0.1, 0.1, 0.2, 0.2],
      track_id: nil,
      observation_kind: kind
    }

  # Two buffers, spaced a beat apart so `System.monotonic_time(:millisecond)`
  # cannot land the same instant for both — the aggregator only confirms
  # across two genuinely distinct `at_ms` values.
  defp two_beats(state, observations) do
    {[], state} = feed(state, observations)
    Process.sleep(5)
    feed(state, observations)
  end

  test "detected objects above the floor forward per-label best scores, confirming after two buffers",
       ctx do
    id = ctx.camera_id
    state = sink(ctx)

    {[], state} = feed(state, [frame([object("person", 0.6)])])
    Process.sleep(5)
    {[], _state} = feed(state, [frame([object("person", 0.9)])])

    assert_receive {:presence_started,
                    %PresenceEvent{camera_id: ^id, label: "person", score: 0.9}}
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

    assert_receive {:presence_cleared, %PresenceEvent{camera_id: ^id, label: "person"}}
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
end
