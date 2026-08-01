defmodule Cairn.PluginProtocolIntegrationTest do
  @moduledoc """
  The plugin wire protocol end to end, through real OS processes.

  A real mock plugin process speaks protocol v1 (and, in the last test, v0)
  over a real `Port` — stdout ndjson in, control lines out on stdin — into
  `Cairn.PluginPort` / `Cairn.PluginGroupPort`, the global
  `Cairn.DetectionAggregator`, and out as the SSE frames
  `CairnWeb.Api.EventStreamController` builds. Both plugin shapes are covered:
  one process per camera and one process per group.

  What each test is really about is the **stream epoch boundary**
  (`docs/plugin-contract.md` → Stream epochs): the plugin is told, its
  pre-boundary lines are refused, its identities do not survive the cut, and
  a group member's boundary touches nobody else.

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

  setup do
    dir = Path.join(System.tmp_dir!(), "cairn_proto_#{System.unique_integer([:positive])}")
    Cairn.DataDir.ensure!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    %{dir: dir}
  end

  describe "per-camera plugin, protocol v1" do
    test "an epoch bounce is announced, cuts identity, and refuses pre-boundary lines",
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
          %{
            at_ms: 120,
            pts: 108_000,
            dets: [det(0.92, "t1")],
            await_epoch_change: true,
            epoch: "previous"
          },
          # The same envelope and the same track id as the refused line, with
          # a live epoch instead of a retired one. It is accepted, which is
          # what makes the refusal above about the epoch and nothing else —
          # and identity must NOT carry over.
          %{at_ms: 240, pts: 9_000, dets: [det(0.93, "t1")]}
        ])

      camera = camera(camera_id, ["--timeline", timeline, "--object-tracking"])
      config = config(dir)

      CameraControl.set(camera_id, %{recording_enabled: false})
      Cairn.Event.subscribe()

      epoch_a = StreamEpochs.new_epoch(camera_id, :started)
      port = start_supervised!({PluginPort, camera: camera, config: config, index: 0})

      # The plugin declared `object_tracking`, so its own id owns the identity.
      assert_receive {:track_started,
                      %Track{
                        camera_id: ^camera_id,
                        object_id: object_a,
                        source: :plugin,
                        plugin_track_id: "t1",
                        epoch: ^epoch_a
                      }},
                     30_000

      # Positive control for the stale-drop assertion below: nothing has been
      # refused for this reason yet, so a later count cannot be pre-existing.
      refute Map.has_key?(:sys.get_state(port).drops, :stale_epoch)

      epoch_b = StreamEpochs.new_epoch(camera_id, :source_lost)

      # Nothing may span the cut: the live track gets a final summary...
      assert_receive {:track_ended,
                      %Track{
                        camera_id: ^camera_id,
                        object_id: ^object_a,
                        end_reason: :stream_reset,
                        epoch: ^epoch_a
                      } = ended},
                     30_000

      # What the refused line did *not* do, by score rather than by a counter:
      # `best_score` is a monotone max with no throttle on it, the only line
      # this track ever accepted carries 0.90, and both lines after it carry
      # more. So the summary reads 0.90 exactly when nothing crossed the cut
      # in either direction.
      #
      # Note what this cannot show: a *plugin-owned* track is ended by the
      # epoch broadcast itself (only host-mode tracks are suspended for
      # adoption), so this summary is closed before the stale line is even
      # emitted. A line refused *after* the cut could never have reached it,
      # and the port's refusal is proven by the exact drops map below plus the
      # next line — same shape, same track id, live epoch — being accepted.
      assert ended.best_score == 0.90, "a post-boundary line reached the pre-boundary track"

      # ...and that is what a Home Assistant client actually receives.
      assert {:ok, frame} = EventStreamController.frame_for({:track_ended, ended})
      assert frame =~ "event: track_ended\n"
      assert frame =~ ~s("end_reason":"stream_reset")
      assert frame =~ object_a

      # The same plugin track id after the boundary is a different object.
      assert_receive {:track_started,
                      %Track{
                        camera_id: ^camera_id,
                        object_id: object_b,
                        source: :plugin,
                        plugin_track_id: "t1",
                        epoch: ^epoch_b
                      }},
                     30_000

      assert object_b != object_a

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
          %{
            camera_id: cam_a,
            at_ms: 120,
            pts: 99_000,
            dets: [det(0.91, "ta")],
            await_epoch_change: true,
            epoch: "previous"
          },
          %{camera_id: cam_a, at_ms: 240, pts: 9_000, dets: [det(0.92, "ta")]},
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
                        plugin_track_id: "ta",
                        epoch: ^epoch_a1
                      }},
                     30_000

      assert_receive {:track_started,
                      %Track{
                        camera_id: ^cam_b,
                        object_id: object_b1,
                        plugin_track_id: "tb",
                        epoch: ^epoch_b1
                      }},
                     30_000

      epoch_a2 = StreamEpochs.new_epoch(cam_a, :stall_bounce)

      assert_receive {:track_ended,
                      %Track{
                        camera_id: ^cam_a,
                        object_id: ^object_a1,
                        end_reason: :stream_reset,
                        epoch: ^epoch_a1
                      } = ended_a},
                     30_000

      # Per camera, which the group's own drop counters are not (see below):
      # the only line this track accepted carries 0.90, and both cam_a lines
      # after it carry more, so the summary reads 0.90 exactly when nothing
      # crossed the cut in either direction. As in the per-camera test, this
      # cannot show the *port's* refusal on its own — this track is
      # plugin-owned, so the epoch broadcast closes its summary outright,
      # before the stale line is emitted.
      assert ended_a.best_score == 0.90, "a post-boundary line reached the pre-boundary track"

      # ...and that is what a Home Assistant client actually receives. The
      # group path reaches the SSE boundary the same way the per-camera one
      # does; these events arrive on `Cairn.Event.topic()`, which is the topic
      # `CairnWeb.Api.EventStreamController` subscribes to.
      assert {:ok, frame} = EventStreamController.frame_for({:track_ended, ended_a})
      assert frame =~ "event: track_ended\n"
      assert frame =~ ~s("end_reason":"stream_reset")
      assert frame =~ ~s("camera_id":"#{cam_a}")
      assert frame =~ object_a1

      assert_receive {:track_started,
                      %Track{camera_id: ^cam_a, object_id: object_a2, epoch: ^epoch_a2}},
                     30_000

      assert object_a2 != object_a1

      # A group's drop counters are flat across its members — the camera
      # appears only in the log detail — so this pins *what* was refused and
      # how often, not whose it was. Only cam_a emits a stale line, and its
      # `best_score` above is the per-camera half of the proof.
      assert :sys.get_state(port).drops == %{stale_epoch: 1}

      # The other member kept its identity across its neighbour's boundary.
      # This message and cam_a's `track_ended` come from the same aggregator
      # process, so receiving it makes the refute below "nothing arrived up to
      # this point" rather than "nothing has arrived yet".
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

  defp det(score, track_id) do
    %{
      label: "person",
      score: score,
      bbox: [0.1, 0.1, 0.2, 0.4],
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
