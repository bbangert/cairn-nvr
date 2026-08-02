defmodule Cairn.PluginProtocolIntegrationTest do
  @moduledoc """
  The plugin wire protocol end to end, through real OS processes.

  A real mock plugin process speaks protocol v1 (and, in the last test, v0)
  over a real `Port` — stdout ndjson in, control lines out on stdin — into
  `Cairn.PluginPort` / `Cairn.PluginGroupPort`, on into each camera's
  `Cairn.CameraTracker`, and out as the SSE frames
  `CairnWeb.Api.EventStreamController` builds. Both plugin shapes are covered:
  one process per camera and one process per group.

  What each test is really about is the **stream epoch boundary**
  (`docs/plugin-contract.md` → Stream epochs): the plugin is told, its
  pre-boundary lines are refused, a box on the far side that matches nothing
  suspended mints a new identity, and a group member's boundary touches
  nobody else.

  ffmpeg is deliberately absent: the epoch is driven through
  `Cairn.StreamEpochs` so the boundary lands at an exact point in the
  plugin's timeline rather than whenever a respawn happens to occur. The mock
  blocks on the announcement itself (`await_epoch_change`), so no step here
  waits on a sleep.

  Recording is disabled per camera: these tests are about the observation
  path, and an event would drag a ring buffer and an extractor in with it
  (`Cairn.FullPipelineTest` covers that path).

  Excluded by default (`test_helper.exs`); run with
  `mix test --include integration`.
  """

  use Cairn.DataCase, async: false

  @moduletag :integration
  @moduletag timeout: 120_000

  alias Cairn.{CameraControl, Config, PluginGroupPort, PluginPort, StreamEpochs, Track}
  alias Cairn.Config.Camera
  alias CairnWeb.Api.EventStreamController

  @mock Path.absname("priv/plugins/mock/mock_plugin.exs")
  # The host announces the replacement epoch synchronously, from this process,
  # the moment `track_started` arrives — so this is slack for a loaded CI box,
  # not a wait anything is expected to use. Sized well under the 30 s
  # `assert_receive`s below: exceeding it halts the mock, which fails those
  # assertions immediately instead of eating their budget.
  @epoch_wait_ms "5000"

  # Identity is host-side IoU, so the boxes are what decide it. `@near_box` is
  # every line's default; `@far_box` overlaps it not at all, so a line carrying
  # it can neither match a live track nor adopt a suspended one and has to mint.
  @near_box [0.1, 0.1, 0.2, 0.4]
  @far_box [0.6, 0.6, 0.2, 0.4]

  setup do
    dir = Path.join(System.tmp_dir!(), "cairn_proto_#{System.unique_integer([:positive])}")
    Cairn.DataDir.ensure!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    %{dir: dir}
  end

  describe "per-camera plugin, protocol v1" do
    test "an epoch bounce is announced, suspends identity, and refuses pre-boundary lines",
         %{dir: dir} do
      camera_id = unique_id("v1cam")

      timeline =
        write_timeline(dir, [
          # The only line accepted under the first epoch: the test mints the
          # replacement the moment this one's track is published, and every
          # entry after it waits for that mint. Scores are distinct so the
          # final summary names which lines reached the track.
          %{at_ms: 0, pts: 90_000, dets: [det(0.90, "t1")]},
          # Blocks until the host announces the replacement epoch, then emits
          # one line stamped with the epoch that just ended: a stale line the
          # host must refuse, produced deterministically rather than raced for.
          # Its box is the live track's own and its score is the highest in the
          # timeline, so had it been accepted it would have updated that track
          # and said so — which is the refutation below.
          %{
            at_ms: 120,
            pts: 108_000,
            dets: [det(0.99, "t1")],
            await_epoch_change: true,
            epoch: "previous"
          },
          # The same envelope and the same track id as the refused line, with a
          # live epoch instead of a retired one, and a box nowhere near the
          # suspended track's. It is accepted — which is what makes the refusal
          # above about the epoch and nothing else — and it mints rather than
          # adopting, because nothing suspended overlaps it.
          %{at_ms: 240, pts: 9_000, dets: [det(0.93, "t1", @far_box)]}
        ])

      camera = camera(camera_id, ["--timeline", timeline, "--object-tracking"])
      config = config(dir)

      CameraControl.set(camera_id, %{recording_enabled: false})
      Cairn.Event.subscribe()

      epoch_a = StreamEpochs.new_epoch(camera_id, :started)
      port = start_supervised!({PluginPort, camera: camera, config: config, index: 0})

      # The plugin declared `object_tracking` and it bought it nothing: the
      # identity is the host's, and the track id it sent is not on the summary.
      assert_receive {:track_started,
                      %Track{
                        camera_id: ^camera_id,
                        object_id: object_a,
                        source: :host,
                        plugin_track_id: nil,
                        epoch: ^epoch_a
                      }},
                     30_000

      # Positive control for the stale-drop assertion below: nothing has been
      # refused for this reason yet, so a later count cannot be pre-existing.
      refute Map.has_key?(:sys.get_state(port).drops, :stale_epoch)

      epoch_b = StreamEpochs.new_epoch(camera_id, :source_lost)

      # The cut *suspends* the live track rather than ending it, so no final
      # goes out here — one is owed only once the adoption window runs out with
      # nothing having adopted it, a minute later.
      #
      # The far-box line after the boundary therefore mints: it overlaps the
      # suspension not at all, so nothing carries the old identity forward.
      assert_receive {:track_started,
                      %Track{
                        camera_id: ^camera_id,
                        object_id: object_b,
                        source: :host,
                        plugin_track_id: nil,
                        epoch: ^epoch_b
                      } = started},
                     30_000

      assert object_b != object_a

      # ...and that is what a Home Assistant client actually receives.
      assert {:ok, frame} = EventStreamController.frame_for({:track_started, started})
      assert frame =~ "event: track_started\n"
      assert frame =~ ~s("source":"host")
      assert frame =~ object_b

      # What the refused line did *not* do. It carried the suspended track's own
      # box and the timeline's best score, so accepting it would have adopted
      # that track and published an update for it. Both tracks are this
      # camera's, so both frames come from its one `Cairn.CameraTracker` —
      # nothing is merely in flight by now.
      refute_received {:track_updated, %Track{object_id: ^object_a}}
      refute_received {:track_ended, %Track{object_id: ^object_a}}

      # That post-boundary line was emitted after the stale one on the same
      # stdout, so by now the port has already accounted for the stale line —
      # and pinned exactly, because the classes a refusal is reported under
      # are what an operator reads. The refused line consumed one of the
      # plugin's sequence numbers; the epoch that replaced it starts a new
      # sequence timeline, so that number is not also a lost frame.
      assert :sys.get_state(port).drops == %{stale_epoch: 1}

      # The plugin was told, on stdin, in the documented order.
      log = File.read!(Path.join(Cairn.DataDir.log_dir(dir), "plugin-#{camera_id}.log"))
      assert log =~ "stream.started #{camera_id} #{epoch_a}"
      assert log =~ "stream.ended #{camera_id} (source_lost)"
      assert log =~ "stream.started #{camera_id} #{epoch_b}"
    end
  end

  describe "group plugin, protocol v1" do
    test "one member's epoch bounce leaves the other member's stream untouched",
         %{dir: dir} do
      cam_a = unique_id("v1grpa")
      cam_b = unique_id("v1grpb")

      timeline =
        write_timeline(dir, [
          %{camera_id: cam_a, at_ms: 0, pts: 90_000, dets: [det(0.90, "ta")]},
          %{camera_id: cam_b, at_ms: 60, pts: 90_000, dets: [det(0.90, "tb")]},
          # cam_a's stale line carries its live track's own box and the best
          # score that track will ever be offered: accepting it would show up
          # as an update, which is what the refutation below rests on.
          %{
            camera_id: cam_a,
            at_ms: 120,
            pts: 99_000,
            dets: [det(0.99, "ta")],
            await_epoch_change: true,
            epoch: "previous"
          },
          # Far from the suspended box, so it mints instead of adopting.
          %{camera_id: cam_a, at_ms: 240, pts: 9_000, dets: [det(0.92, "ta", @far_box)]},
          # cam_b never bounced: a better score keeps its identity and beats
          # the update throttle, so its survival is asserted, not assumed.
          %{camera_id: cam_b, at_ms: 300, pts: 99_000, dets: [det(0.95, "tb")]}
        ])

      config = group_config(dir, timeline, [cam_a, cam_b])
      group = Enum.find(config.plugin_groups, &(&1.name == "detect"))
      assert %Config.PluginGroup{members: [_, _]} = group

      for id <- [cam_a, cam_b], do: CameraControl.set(id, %{recording_enabled: false})
      Cairn.Event.subscribe()

      epoch_a1 = StreamEpochs.new_epoch(cam_a, :started)
      epoch_b1 = StreamEpochs.new_epoch(cam_b, :started)

      port = start_supervised!({PluginGroupPort, group: group, config: config})

      assert_receive {:track_started,
                      %Track{
                        camera_id: ^cam_a,
                        object_id: object_a1,
                        source: :host,
                        plugin_track_id: nil,
                        epoch: ^epoch_a1
                      }},
                     30_000

      assert_receive {:track_started,
                      %Track{
                        camera_id: ^cam_b,
                        object_id: object_b1,
                        source: :host,
                        plugin_track_id: nil,
                        epoch: ^epoch_b1
                      }},
                     30_000

      epoch_a2 = StreamEpochs.new_epoch(cam_a, :stall_bounce)

      # cam_a's live track is suspended by the cut rather than ended, so its
      # far-box successor mints instead of adopting and no final goes out here.
      assert_receive {:track_started,
                      %Track{camera_id: ^cam_a, object_id: object_a2, epoch: ^epoch_a2} =
                        started_a},
                     30_000

      assert object_a2 != object_a1

      # ...and that is what a Home Assistant client actually receives. The
      # group path reaches the SSE boundary the same way the per-camera one
      # does; these events arrive on `Cairn.Event.topic()`, which is the topic
      # `CairnWeb.Api.EventStreamController` subscribes to.
      assert {:ok, frame} = EventStreamController.frame_for({:track_started, started_a})
      assert frame =~ "event: track_started\n"
      assert frame =~ ~s("camera_id":"#{cam_a}")
      assert frame =~ object_a2

      # A group's drop counters are flat across its members — the camera
      # appears only in the log detail — so this pins *what* was refused and
      # how often, not whose it was. Only cam_a emits a stale line, and the
      # per-camera half of the proof is the refutation below: that line carried
      # cam_a's suspended box and the best score in the timeline, so accepting
      # it would have adopted that track and published an update for it.
      assert :sys.get_state(port).drops == %{stale_epoch: 1}
      refute_received {:track_updated, %Track{object_id: ^object_a1}}
      refute_received {:track_ended, %Track{object_id: ^object_a1}}

      # The other member kept its identity across its neighbour's boundary.
      # cam_b has a `Cairn.CameraTracker` of its own — cam_a's frames say
      # nothing about when cam_b's arrive — so the barrier for the refute below
      # is this message: it and any `track_ended` for cam_b come from that one
      # process, which makes the refute "nothing arrived up to this point"
      # rather than "nothing has arrived yet".
      assert_receive {:track_updated,
                      %Track{camera_id: ^cam_b, object_id: ^object_b1, epoch: ^epoch_b1}},
                     30_000

      refute_received {:track_ended, %Track{camera_id: ^cam_b}}

      # One log for the whole group, and only cam_a's stream was cut.
      log = File.read!(Path.join(Cairn.DataDir.log_dir(dir), "plugin-detect.log"))
      assert log =~ "stream.started #{cam_a} #{epoch_a1}"
      assert log =~ "stream.started #{cam_b} #{epoch_b1}"
      assert log =~ "stream.ended #{cam_a} (stall_bounce)"
      assert log =~ "stream.started #{cam_a} #{epoch_a2}"
      refute log =~ "stream.ended #{cam_b}"
    end
  end

  describe "protocol v0 compatibility" do
    test "a plugin that sends no hello is served by the v0 adapter path", %{dir: dir} do
      camera_id = unique_id("v0cam")

      timeline =
        write_timeline(dir, [
          %{at_ms: 0, pts: 90_000, dets: [det(0.90, "t1")]},
          %{at_ms: 120, pts: 99_000, dets: [det(0.95, "t1")]}
        ])

      # `--object-tracking` is deliberately passed *with* `--v0`: a v0 plugin
      # sends no hello, so there is no capability to declare and the track ids
      # in its detections must be ignored.
      camera =
        camera(camera_id, ["--timeline", timeline, "--v0", "--object-tracking"])

      config = config(dir)

      CameraControl.set(camera_id, %{recording_enabled: false})
      Cairn.Event.subscribe()

      epoch = StreamEpochs.new_epoch(camera_id, :started)
      port = start_supervised!({PluginPort, camera: camera, config: config, index: 0})

      # Host-side identity, the plugin's own id discarded, and the epoch
      # supplied by the port because a v0 line cannot carry one.
      assert_receive {:track_started,
                      %Track{
                        camera_id: ^camera_id,
                        object_id: object_id,
                        source: :host,
                        plugin_track_id: nil,
                        epoch: ^epoch,
                        label: "person"
                      } = started},
                     30_000

      assert {:ok, frame} = EventStreamController.frame_for({:track_started, started})
      assert frame =~ "event: track_started\n"
      assert frame =~ object_id
      assert frame =~ ~s("source":"host")

      # The second line reached the same track: the adapter path is not just
      # decoding one line, it is feeding a live tracker.
      assert_receive {:track_updated,
                      %Track{camera_id: ^camera_id, object_id: ^object_id, best_score: 0.95}},
                     30_000

      state = :sys.get_state(port)
      assert state.plugin == nil, "a v0 plugin must not be recorded as having said hello"
      refute Map.has_key?(state.drops, :missing_pts_or_dets)
      refute Map.has_key?(state.drops, :stale_epoch)
    end
  end

  # -- helpers ------------------------------------------------------------------

  defp unique_id(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  # `track_id` is on the wire and ignored by the host (see
  # `docs/plugin-contract.md` → Track identity); it is sent here because the
  # protocol still carries it, not because anything reads it.
  defp det(score, track_id, bbox \\ @near_box) do
    %{
      label: "person",
      score: score,
      bbox: bbox,
      track_id: track_id,
      observation_kind: "detected"
    }
  end

  defp write_timeline(dir, entries) do
    path = Path.join(dir, "timeline_#{System.unique_integer([:positive])}.json")
    File.write!(path, Jason.encode!(entries))
    path
  end

  # `--hold` keeps the process alive after the timeline so the port does not
  # respawn it into a replay halfway through an assertion.
  defp mock_argv(extra),
    do: ["elixir", @mock] ++ extra ++ ["--hold", "--epoch-wait-ms", @epoch_wait_ms]

  defp camera(camera_id, extra) do
    %Camera{
      id: camera_id,
      rtsp_url: "rtsp://example.invalid/stream",
      plugin: {:inline, mock_argv(extra)},
      min_score: %{"default" => 0.5}
    }
  end

  defp config(dir) do
    %Config{
      data_dir: dir,
      udp_base_port: 19_600,
      udp_port_range: 8,
      pre_window_seconds: 4,
      post_window_seconds: 3,
      max_event_seconds: 60
    }
  end

  # Parsed from a config map rather than built by hand: the group's members,
  # their ports and their score floors are what the real launch path derives.
  defp group_config(dir, timeline, camera_ids) do
    {:ok, config, []} =
      Config.from_map(%{
        "data_dir" => dir,
        "udp" => %{"base_port" => 19_620, "range" => 12},
        "plugins" => %{
          "detect" => %{"command" => mock_argv(["--timeline", timeline, "--object-tracking"])}
        },
        "cameras" =>
          Enum.map(camera_ids, fn id ->
            %{
              "id" => id,
              "rtsp_url" => "rtsp://example.invalid/stream",
              "plugin" => "detect",
              "min_score" => %{"default" => 0.5}
            }
          end)
      })

    config
  end
end
