defmodule Cairn.CameraTrackerControlTest do
  # verifies runtime CameraControl toggles change a camera tracker's behavior
  #
  # DataCase, not ExUnit.Case: starting a tracker runs checkpoint restore,
  # which consults the event index — that Repo call needs a sandbox owner.
  use Cairn.DataCase, async: false

  alias Cairn.{CameraControl, CameraTracker, Event, EventCheckpoint, Observation}
  alias Cairn.Config.Camera

  @policy %{pre: 5, post: 10, max: 300, max_unseen_ms: 3_000}

  setup do
    camera_id = "trkc_#{System.unique_integer([:positive])}"
    camera = %Camera{id: camera_id, rtsp_url: "rtsp://h/1", min_score: %{"default" => 0.5}}
    test_pid = self()

    tracker =
      start_supervised!(
        {CameraTracker,
         camera_id: camera_id,
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

    %{tracker: tracker, camera: camera, camera_id: camera_id}
  end

  defp detect(tracker, camera, score \\ 0.9),
    do: detect(tracker, camera, "person", score, @policy)

  defp detect(tracker, camera, label, score, policy) do
    observation = %Observation{
      pts: 90_000,
      observed_at: DateTime.utc_now(),
      objects: [
        %{
          label: label,
          score: score,
          bbox: [0.1, 0.1, 0.2, 0.4],
          track_id: nil,
          observation_kind: "detected"
        }
      ]
    }

    CameraTracker.detections(tracker, camera, policy, observation)
  end

  # `detections/4` is an async cast; flushing the tracker's mailbox with
  # :sys.get_state guarantees it (and its synchronous PubSub broadcast) is done,
  # so we can assert "no event" with no timing window.
  defp refute_event_started(tracker) do
    :sys.get_state(tracker)
    refute_received {:event_started, _}
  end

  test "detection_enabled=false drops batches — no event starts", ctx do
    CameraControl.set(ctx.camera_id, %{detection_enabled: false})

    detect(ctx.tracker, ctx.camera)

    refute_event_started(ctx.tracker)
  end

  test "recording_enabled=false suppresses event start", ctx do
    CameraControl.set(ctx.camera_id, %{recording_enabled: false})

    detect(ctx.tracker, ctx.camera)

    refute_event_started(ctx.tracker)
  end

  test "min_score override raises the threshold", ctx do
    CameraControl.set(ctx.camera_id, %{min_score: 0.95})

    # 0.9 is above the configured 0.5 but below the 0.95 override → filtered out
    detect(ctx.tracker, ctx.camera, 0.9)
    refute_event_started(ctx.tracker)

    # above the override → passes
    detect(ctx.tracker, ctx.camera, 0.99)
    assert_receive {:event_started, %Event{camera_id: cid}}
    assert cid == ctx.camera_id
  end

  test "defaults (no control set) behave exactly as configured", ctx do
    detect(ctx.tracker, ctx.camera, 0.9)
    assert_receive {:event_started, %Event{camera_id: cid}}
    assert cid == ctx.camera_id
  end

  describe "a min_score override under a record: tier" do
    # The override moves the floor; the tier says what earns video. Evidence
    # needs both — `score >= max(effective_min_score, tier)` — so the override
    # can raise the bar at runtime but can neither undercut the tier nor
    # un-exclude a label the block leaves out.
    @record_rules %{"person" => %{min_score: 0.6}}
    @record_policy Map.put(@policy, :record, @record_rules)

    setup ctx do
      %{ctx | camera: %{ctx.camera | min_score: %{"default" => 0.4}, record: @record_rules}}
    end

    test "an override above the tier raises the bar", ctx do
      CameraControl.set(ctx.camera_id, %{min_score: 0.8})

      # clears record.person (0.6) but not the override
      detect(ctx.tracker, ctx.camera, "person", 0.7, @record_policy)
      refute_event_started(ctx.tracker)

      detect(ctx.tracker, ctx.camera, "person", 0.85, @record_policy)
      assert_receive {:event_started, %Event{camera_id: _}}
    end

    test "an override below the tier does not lower it", ctx do
      CameraControl.set(ctx.camera_id, %{min_score: 0.3})

      # clears the lowered floor, still under record.person
      detect(ctx.tracker, ctx.camera, "person", 0.5, @record_policy)
      refute_event_started(ctx.tracker)

      detect(ctx.tracker, ctx.camera, "person", 0.65, @record_policy)
      assert_receive {:event_started, %Event{camera_id: _}}
    end

    test "a label the block leaves out stays out whatever the override", ctx do
      for override <- [nil, 0.1, 0.99] do
        CameraControl.set(ctx.camera_id, %{min_score: override})

        detect(ctx.tracker, ctx.camera, "cat", 0.99, @record_policy)
        refute_event_started(ctx.tracker)
      end
    end
  end
end
