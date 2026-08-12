defmodule Cairn.Pipeline.TrackSinkTest do
  use ExUnit.Case, async: true

  alias Cairn.Config.Camera
  alias Cairn.Pipeline.TrackSink
  alias Cairn.Track
  alias Membrane.Buffer

  @policy %{
    pre: 5,
    post: 10,
    max: 300,
    track: %{"person" => %{min_score: 0.4}},
    record: %{"person" => %{min_score: 0.6}}
  }

  setup do
    camera_id = "tsink_#{System.unique_integer([:positive])}"

    %{
      camera_id: camera_id,
      camera: %Camera{id: camera_id, rtsp_url: "rtsp://h/1"},
      epoch: Cairn.ULID.generate()
    }
  end

  defp sink(ctx) do
    options =
      struct(TrackSink,
        camera: ctx.camera,
        policy: @policy,
        # the dispatch seam's injection point: this process stands in for
        # the camera's tracker and sees the casts it would have received
        tracker: self()
      )

    {[], state} = TrackSink.handle_init(%{}, options)
    state
  end

  defp track(ctx, object_id) do
    %Track{
      object_id: object_id,
      camera_id: ctx.camera_id,
      label: "person",
      score: 0.9,
      best_score: 0.9,
      bbox: [0.1, 0.1, 0.2, 0.4],
      epoch: ctx.epoch
    }
  end

  # `Membrane.MOTTracker`'s out-pad contract.
  defp feed(state, ctx, metadata) do
    buffer = %Buffer{
      payload: <<>>,
      pts: 1,
      metadata:
        Map.merge(
          %{
            tagged: [],
            events: [],
            suspension: nil,
            snapshot: [],
            epoch: ctx.epoch,
            context: %{observed_at: DateTime.utc_now(), min_score: %{"default" => 0.5}}
          },
          metadata
        )
    }

    {[], state} = TrackSink.handle_buffer(:input, buffer, %{}, state)
    state
  end

  test "a batch reaches the tracker through the dispatch seam", ctx do
    tagged = [%{object_id: "o1", label: "person", score: 0.9, bbox: [0, 0, 1, 1]}]
    snapshot = [track(ctx, "o1")]

    _state =
      feed(sink(ctx), ctx, %{
        tagged: tagged,
        events: [{:started, track(ctx, "o1")}],
        snapshot: snapshot
      })

    camera = ctx.camera
    epoch = ctx.epoch

    # the same cast every producer makes, carrying the same policy —
    # `track:` and `record:` included, and neither read on the way
    assert_received {:"$gen_cast", {:tracked, ^camera, @policy, batch}}
    assert %{tagged: ^tagged, snapshot: ^snapshot, epoch: ^epoch} = batch
    assert [{:started, %Track{object_id: "o1"}}] = batch.events
  end

  test "the context is flattened to what the event lifecycle reads", ctx do
    observed_at = ~U[2026-08-12 10:00:00.000000Z]

    _state =
      feed(sink(ctx), ctx, %{
        context: %{observed_at: observed_at, min_score: %{"default" => 0.7}, at_ms: 5}
      })

    assert_received {:"$gen_cast", {:tracked, _camera, _policy, batch}}
    assert batch.observed_at == observed_at
    assert batch.min_score == %{"default" => 0.7}
  end

  test "an element buffer with no context carries its events and nothing else", ctx do
    # the lapsed-suspension buffer: no batch produced it, so it dates nothing
    _state = feed(sink(ctx), ctx, %{events: [{:ended, track(ctx, "o1")}], context: nil})

    assert_received {:"$gen_cast", {:tracked, _camera, _policy, batch}}
    assert batch.observed_at == nil
    assert batch.min_score == nil
    assert [{:ended, %Track{}}] = batch.events
  end

  test "a buffer without the contract is dropped and counted, not crashed on", ctx do
    {[], state} =
      TrackSink.handle_buffer(
        :input,
        %Buffer{payload: <<>>, metadata: %{tagged: []}},
        %{},
        sink(ctx)
      )

    assert state.dropped == 1
    refute_received {:"$gen_cast", {:tracked, _camera, _policy, _batch}}
  end

  test "stats count what was dispatched and when the branch was last alive", ctx do
    state = sink(ctx)

    # nil until a buffer lands: a branch that has never produced is not the
    # same as one that has stopped, and the watchdog reads exactly this
    assert {[notify_parent: {:stats, %{last_buffer_at_ms: nil}}], _state} =
             TrackSink.handle_parent_notification(:stats, %{}, state)

    state = feed(state, ctx, %{})

    assert {[notify_parent: {:stats, %{dispatched: 1, last_buffer_at_ms: at_ms}}], _state} =
             TrackSink.handle_parent_notification(:stats, %{}, state)

    assert_in_delta at_ms, System.monotonic_time(:millisecond), 5_000
  end

  test "the element's own buffers are not a sign of life", ctx do
    # a suspension lapsing while the stream stays down produces one of these,
    # and a branch that has decoded nothing since the cut must still read stale
    state = feed(sink(ctx), ctx, %{})

    assert {[notify_parent: {:stats, %{last_buffer_at_ms: alive_at}}], _state} =
             TrackSink.handle_parent_notification(:stats, %{}, state)

    state = feed(state, ctx, %{context: nil, events: [{:ended, track(ctx, "o1")}]})

    assert {[notify_parent: {:stats, %{dispatched: 2, last_buffer_at_ms: ^alive_at}}], _state} =
             TrackSink.handle_parent_notification(:stats, %{}, state)
  end

  test "carries a refreshed policy without restarting anything", ctx do
    state = sink(ctx)
    camera = %{ctx.camera | record: %{"person" => %{min_score: 0.9}}}
    policy = Map.put(@policy, :record, camera.record)

    {actions, state} =
      TrackSink.handle_parent_notification({:policy, camera, policy}, %{}, state)

    assert actions == []

    _state = feed(state, ctx, %{})
    assert_received {:"$gen_cast", {:tracked, ^camera, ^policy, _batch}}
  end
end
