defmodule Cairn.EventArtifactTest do
  # async: false — the `"events"` topic is process-global
  use ExUnit.Case, async: false

  alias Cairn.{Event, EventArtifact}

  setup do
    Event.subscribe()
    %{artifact: %EventArtifact{event_id: Ecto.UUID.generate(), camera_id: "guard_cam"}}
  end

  test "a ready kind carries a path and a byte count", %{artifact: artifact} do
    ready = %{artifact | path: "/clips/e.mp4", bytes: 0}
    event_id = artifact.event_id

    EventArtifact.broadcast(:event_clip_ready, ready)
    assert_receive {:event_clip_ready, %EventArtifact{event_id: ^event_id, bytes: 0}}

    EventArtifact.broadcast(:event_snapshot_ready, ready)
    assert_receive {:event_snapshot_ready, %EventArtifact{event_id: ^event_id}}
  end

  test "a failed kind carries a reason from the closed set", %{artifact: artifact} do
    for reason <- [:not_found, :index_write_failed, :no_output, :exception] do
      EventArtifact.broadcast(:event_clip_failed, %{artifact | reason: reason})
      assert_receive {:event_clip_failed, %EventArtifact{reason: ^reason}}

      EventArtifact.broadcast(:event_snapshot_failed, %{artifact | reason: reason})
      assert_receive {:event_snapshot_failed, %EventArtifact{reason: ^reason}}
    end
  end

  # The docs sell the guards as the thing that keeps the two shapes apart, so
  # the combinations in between must not quietly pick a clause: an artifact
  # with everything nil used to match *both*, announcing a `clip_url` for a
  # file that does not exist or a `"reason": null` no consumer can branch on.
  describe "combinations that are neither shape" do
    test "an artifact with nothing set matches no kind at all", %{artifact: artifact} do
      refute_shape(:event_clip_ready, artifact, [])
      refute_shape(:event_snapshot_ready, artifact, [])
      refute_shape(:event_clip_failed, artifact, [])
      refute_shape(:event_snapshot_failed, artifact, [])
    end

    test "a ready artifact needs both halves of the pair", %{artifact: artifact} do
      refute_shape(:event_clip_ready, artifact, path: "/clips/e.mp4")
      refute_shape(:event_clip_ready, artifact, bytes: 12)
    end

    test "a ready artifact may not also carry a reason", %{artifact: artifact} do
      refute_shape(:event_clip_ready, artifact,
        path: "/clips/e.mp4",
        bytes: 12,
        reason: :no_output
      )
    end

    test "a failed artifact may not carry media", %{artifact: artifact} do
      refute_shape(:event_snapshot_failed, artifact,
        reason: :no_output,
        path: "/snaps/e.jpg",
        bytes: 12
      )
    end

    test "a reason outside the closed set never reaches the wire", %{artifact: artifact} do
      refute_shape(:event_clip_failed, artifact, reason: :ffmpeg_said_no)
    end
  end

  # Built through `struct!/2` rather than as a literal: the guard exists for
  # artifacts assembled at runtime, and a literal here would (rightly) be a
  # compile-time type warning instead of the runtime raise under test.
  defp refute_shape(kind, artifact, fields) do
    assert_raise FunctionClauseError, fn ->
      EventArtifact.broadcast(kind, struct!(artifact, fields))
    end
  end
end
