defmodule Cairn.Config.ServerTest do
  use ExUnit.Case, async: true

  alias Cairn.Config

  @base """
  data_dir: <%= data_dir %>
  cameras:
    - id: cam_a
      rtsp_url: rtsp://h/1
    - id: cam_b
      rtsp_url: rtsp://h/2
  """

  setup do
    dir = Path.join(System.tmp_dir!(), "cairn_srv_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    path = Path.join(dir, "config.yml")
    File.write!(path, EEx.eval_string(@base, data_dir: Path.join(dir, "data")))

    test_pid = self()
    apply_diff = fn diff, config -> send(test_pid, {:applied, diff, config}) end
    apply_native = fn config -> send(test_pid, {:native_applied, config}) end

    server =
      start_supervised!(
        {Config.Server,
         path: path, name: nil, apply_diff: apply_diff, apply_native: apply_native},
        id: :config_server_under_test
      )

    %{dir: dir, path: path, server: server}
  end

  test "loads config and ensures data dirs", %{server: server, dir: dir} do
    config = Config.Server.get(server)
    assert [%{id: "cam_a"}, %{id: "cam_b"}] = config.cameras
    assert File.dir?(Path.join([dir, "data", "events"]))
    assert File.dir?(Path.join([dir, "data", "log"]))
  end

  test "reload diffs added/removed/changed cameras", %{server: server, path: path, dir: dir} do
    updated = """
    data_dir: #{Path.join(dir, "data")}
    cameras:
      - id: cam_a
        rtsp_url: rtsp://h/CHANGED
      - id: cam_c
        rtsp_url: rtsp://h/3
    """

    File.write!(path, updated)

    assert {:ok, diff, []} = Config.Server.reload(server)
    assert diff == %{added: ["cam_c"], removed: ["cam_b"], changed: ["cam_a"], refreshed: []}
    assert_received {:applied, ^diff, %Config{}}

    assert [%{id: "cam_a", rtsp_url: "rtsp://h/CHANGED"}, %{id: "cam_c"}] =
             Config.Server.get(server).cameras
  end

  # Detection is the in-VM engine, so the new config has to reach it as well
  # as the camera diff — it is where a changed profile becomes a changed
  # model — and it has to reach it FIRST: the model a restarted camera opens
  # a stream on should already be the new one.
  test "reload hands the new config to the in-VM engine before the cameras", %{
    server: server,
    path: path,
    dir: dir
  } do
    File.write!(path, """
    data_dir: #{Path.join(dir, "data")}
    cameras:
      - id: cam_a
        rtsp_url: rtsp://h/CHANGED
    """)

    assert {:ok, _diff, []} = Config.Server.reload(server)

    # oldest message first: the engine, then the cameras
    assert_received first
    assert {:native_applied, %Config{cameras: [%{id: "cam_a"}]}} = first

    assert_received second
    assert {:applied, %{changed: ["cam_a"]}, %Config{}} = second
  end

  # The pre window is the one that restarts: the ring is sized from it at tree
  # init, so it cannot be swapped into a running camera.
  test "global pre-window change marks all cameras changed", %{
    server: server,
    path: path,
    dir: dir
  } do
    updated = """
    data_dir: #{Path.join(dir, "data")}
    events:
      pre_window_seconds: 8
    cameras:
      - id: cam_a
        rtsp_url: rtsp://h/1
      - id: cam_b
        rtsp_url: rtsp://h/2
    """

    File.write!(path, updated)

    assert {:ok, %{changed: ["cam_a", "cam_b"], added: [], removed: [], refreshed: []}, []} =
             Config.Server.reload(server)
  end

  test "global post-window change refreshes every camera instead", %{
    server: server,
    path: path,
    dir: dir
  } do
    updated = """
    data_dir: #{Path.join(dir, "data")}
    events:
      post_window_seconds: 42
    cameras:
      - id: cam_a
        rtsp_url: rtsp://h/1
      - id: cam_b
        rtsp_url: rtsp://h/2
    """

    File.write!(path, updated)

    assert {:ok, %{changed: [], added: [], removed: [], refreshed: ["cam_a", "cam_b"]}, []} =
             Config.Server.reload(server)
  end

  test "reordering cameras moves nothing — nothing positional is left", %{
    server: server,
    path: path,
    dir: dir
  } do
    updated = """
    data_dir: #{Path.join(dir, "data")}
    cameras:
      - id: cam_b
        rtsp_url: rtsp://h/2
      - id: cam_a
        rtsp_url: rtsp://h/1
    """

    File.write!(path, updated)

    assert {:ok, %{changed: [], added: [], removed: [], refreshed: []}, []} =
             Config.Server.reload(server)
  end

  describe "diff_cameras/2" do
    test "an identical camera is in neither list" do
      assert camera_diff(%{}) == %{added: [], removed: [], changed: [], refreshed: []}
    end

    test "host-side edits refresh the camera instead of restarting it" do
      for edit <- [
            %{"post_window_seconds" => 42},
            %{"max_event_seconds" => 120},
            %{"max_unseen_ms" => 5_000},
            %{"stationary_after_ms" => 20_000},
            %{"track" => %{"person" => 0.5}},
            %{"record" => %{"person" => 0.8}},
            %{"retention" => %{"days" => 3}}
          ] do
        assert camera_diff(edit) ==
                 %{added: [], removed: [], changed: [], refreshed: ["cam_a"]},
               "expected #{inspect(edit)} to refresh, not restart"
      end
    end

    test "edits that reach a subprocess (or the ring) restart the camera" do
      for edit <- [
            %{"rtsp_url" => "rtsp://h/CHANGED"},
            # Adding, dropping or repointing the sub stream builds a different
            # pipeline — a second ingest, and a detect branch off another tee.
            %{"substream_url" => "rtsp://h/1_sub"},
            %{"min_score" => 0.7},
            %{"transcode" => true},
            %{"extra_ffmpeg_args" => ["-rtsp_transport", "tcp"]},
            %{"pre_window_seconds" => 8},
            # The gate element is built into the branch at birth.
            %{"motion_json" => ~s({"enabled": true, "threshold": 30})}
          ] do
        assert camera_diff(edit) ==
                 %{added: [], removed: [], changed: ["cam_a"], refreshed: []},
               "expected #{inspect(edit)} to restart"
      end
    end

    test "pointing a camera at a plugin group restarts it — the detect branch is per-session" do
      base = %{"id" => "cam_a", "rtsp_url" => "rtsp://h/1"}

      assert Config.Server.diff_cameras(
               profiled_config([base]),
               profiled_config([Map.put(base, "plugin", "detect")])
             ) == %{added: [], removed: [], changed: ["cam_a"], refreshed: []}
    end

    test "naming a different tracker core restarts the camera, at any level" do
      # The core is wired into the detect branch as an element; a running
      # pipeline cannot re-wire one, so the swap has to be a restart — and it
      # can be named on the camera or on the global, which is why the
      # comparison is of the *resolved* answer.
      assert camera_diff(%{"tracker" => "sparsetrack"}) ==
               %{added: [], removed: [], changed: ["cam_a"], refreshed: []}

      assert camera_diff(%{}, %{"tracking" => %{"tracker" => "sparsetrack"}}) ==
               %{added: [], removed: [], changed: ["cam_a"], refreshed: []}
    end

    test "claiming a different tier restarts the camera — the tail is built, not refreshed" do
      # The tier picks the detect branch's whole tail (presence sink vs the
      # tracking chain) at build; a refresh routed by the old tail would
      # feed the new policy to a shape the tier no longer means.
      dir = Path.join(System.tmp_dir!(), "cairn_srv_tier_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      base_yaml = """
      backend: ort
      model:
        onnx: test/support/fixtures/models/stub.onnx
      """

      config = fn yaml ->
        File.write!(Path.join(dir, "tiered.yml"), yaml)

        from_map!(%{
          "data_dir" => "tmp/cfg_srv_test",
          "profile_dirs" => [dir],
          "plugins" => %{"det" => %{"profile" => "tiered"}},
          "cameras" => [%{"id" => "cam_a", "rtsp_url" => "rtsp://h/1", "plugin" => "det"}]
        })
      end

      old = config.(base_yaml)
      new = config.(base_yaml <> "tier: 2\n")

      assert Config.Server.diff_cameras(old, new) ==
               %{added: [], removed: [], changed: ["cam_a"], refreshed: []}
    end

    test "raising the live-track cap restarts the camera, at any level" do
      # The cap is construction input to the detect branch — the element's
      # `max_suspended` and a frame-counting core's `max_live` — so a running
      # branch keeps the old one however the policy is refreshed, and it can be
      # raised on the camera or above it.
      assert camera_diff(%{"max_live_tracks" => 16}) ==
               %{added: [], removed: [], changed: ["cam_a"], refreshed: []}

      assert camera_diff(%{}, %{"tracking" => %{"max_live_tracks" => 16}}) ==
               %{added: [], removed: [], changed: ["cam_a"], refreshed: []}
    end

    test "a profile's sample_fps restarts the cameras on it" do
      # The rate is baked into the branch at build time (the decoder opens on
      # it, the motion gate sizes its calibration window from it, a
      # frame-counting core its lost-track buffer), and it is a profile field
      # alone — a camera's own struct does not move when it changes.
      base = %{"id" => "cam_a", "rtsp_url" => "rtsp://h/1", "plugin" => "detect"}

      assert Config.Server.diff_cameras(
               profiled_config([base], "partial"),
               profiled_config([base], "sample-fps")
             ) == %{added: [], removed: [], changed: ["cam_a"], refreshed: []}
    end

    test "a fleet edit that crosses a rung boundary restarts the detecting cameras (D-L5)" do
      # None of the surviving cameras' own fields move; N does — and the rung
      # resolution moves with it. Both counts here derive the same floor
      # sample_fps (8 × 1.875 = 15 fits the 17 budget; 26 × 1.875 = 48.75
      # needs the 75 rung, and 26 × effective(3) = 78 > 75 keeps it at the
      # floor), so the restart is carried by the resolved-rung comparison
      # alone — the discriminating case for having it.
      old = ladder_config(8)
      new = ladder_config(26)

      assert Config.sample_fps(old, hd(old.cameras)) == 2
      assert Config.sample_fps(new, hd(new.cameras)) == 2

      diff = Config.Server.diff_cameras(old, new)
      assert diff.changed == Enum.map(1..8, &"cam_0#{&1}")
      assert diff.refreshed == []
      assert length(diff.added) == 18
    end

    test "a fleet edit that only moves the derived rate restarts through the fps row" do
      # Same rung (17 budget holds 2 and 8 cameras), different derived
      # sample_fps (10 at 2 cameras, the floor 2 at 8) — the existing
      # resolved sample_fps comparison carries it (D-L5's rider).
      old = ladder_config(2)
      new = ladder_config(8)

      assert Config.resolved_rung(old, hd(old.cameras)) ==
               Config.resolved_rung(new, hd(new.cameras))

      diff = Config.Server.diff_cameras(old, new)
      assert diff.changed == ["cam_01", "cam_02"]
      assert diff.refreshed == []
    end

    test "an unchanged ladder fleet reloads as a no-op" do
      assert Config.Server.diff_cameras(ladder_config(8), ladder_config(8)) ==
               %{added: [], removed: [], changed: [], refreshed: []}
    end

    test "a capacity-metadata edit that moves neither model nor rate touches nothing" do
      # The budgets going provisional → measured (phase 3's whole deliverable)
      # must not restart a fleet: selection and derived fps are unchanged
      # (8 × 1.875 = 15 fits 17 and 18 alike), and the rung comparison is of
      # the rung's RUNTIME identity, not its authoring metadata.
      assert Config.Server.diff_cameras(ladder_config(8, 17), ladder_config(8, 18)) ==
               %{added: [], removed: [], changed: [], refreshed: []}
    end

    test "a camera edited both ways is restarted, not refreshed" do
      assert camera_diff(%{"rtsp_url" => "rtsp://h/2", "stationary_after_ms" => 20_000}) ==
               %{added: [], removed: [], changed: ["cam_a"], refreshed: []}
    end

    test "flipping a camera's ingest restarts it — the source process itself changes" do
      # :ingest is a @restart_field: it selects the session's source (ffmpeg
      # OS process vs RTSP client) and the pipeline's ingest chain — nothing
      # a running session can swap in place.
      base = %{"id" => "cam_a", "rtsp_url" => "rtsp://h/1"}
      flipped = Map.put(base, "ingest", "rtsp")

      assert Config.Server.diff_cameras(
               camera_config([base], %{}),
               camera_config([flipped], %{})
             ) == %{added: [], removed: [], changed: ["cam_a"], refreshed: []}
    end

    test "a global tracking edit refreshes the cameras that resolve through it" do
      assert camera_diff(%{}, %{"tracking" => %{"stationary_after_ms" => 20_000}}) ==
               %{added: [], removed: [], changed: [], refreshed: ["cam_a"]}
    end

    test "a camera overriding the pre window is untouched when the global moves" do
      overridden = %{"id" => "cam_a", "rtsp_url" => "rtsp://h/1", "pre_window_seconds" => 3}
      old = camera_config([overridden], %{})
      new = camera_config([overridden], %{"events" => %{"pre_window_seconds" => 30}})

      # the override wins in `Config.windows/2`, so the ring this camera would
      # be built with has not moved: no restart, and nothing to refresh either
      assert Config.Server.diff_cameras(old, new) ==
               %{added: [], removed: [], changed: [], refreshed: []}
    end

    test "a camera overriding a global is untouched when that global moves" do
      overridden = %{"id" => "cam_a", "rtsp_url" => "rtsp://h/1", "post_window_seconds" => 7}
      old = camera_config([overridden], %{})
      new = camera_config([overridden], %{"events" => %{"post_window_seconds" => 42}})

      # the override wins in `Config.policy/2`, so nothing this camera resolves
      # moved at all: the classification is on resolved values, not raw globals
      assert Config.Server.diff_cameras(old, new) ==
               %{added: [], removed: [], changed: [], refreshed: []}
    end
  end

  test "invalid reload keeps old config and reports errors", %{server: server, path: path} do
    old = Config.Server.get(server)
    File.write!(path, "cameras: [{id: cam_a}]\n")

    assert {:error, errors} = Config.Server.reload(server)
    assert Enum.any?(errors, &(&1 =~ "rtsp_url is required"))
    refute_received {:applied, _, _}
    assert Config.Server.get(server) == old
    assert %{errors: [_ | _]} = Config.Server.last_load(server)
  end

  # Two configs whose only difference is what `edit` does to cam_a and what
  # `global` adds at the top level, diffed.
  defp camera_diff(edit, global \\ %{}) do
    base = %{"id" => "cam_a", "rtsp_url" => "rtsp://h/1"}

    Config.Server.diff_cameras(
      camera_config([base], %{}),
      camera_config([Map.merge(base, edit)], global)
    )
  end

  defp camera_config(cameras, global) do
    from_map!(Map.merge(%{"data_dir" => "tmp/cfg_srv_test", "cameras" => cameras}, global))
  end

  # A config carrying one profiled group, for camera edits that need a
  # resolvable `plugin:` reference.
  defp profiled_config(cameras, profile \\ "partial") do
    from_map!(%{
      "data_dir" => "tmp/cfg_srv_test",
      "profile_dirs" => ["test/support/fixtures/profiles/argv"],
      "plugins" => %{"detect" => %{"profile" => profile}},
      "cameras" => cameras
    })
  end

  defp from_map!(map) do
    {:ok, config, _warnings} = Config.from_map(map)
    config
  end

  # A two-rung tier-1 ladder (budgets 17 and 75) with `n` detecting cameras,
  # for the D-L5 restart-classification cases. One profile dir per call —
  # `diff_cameras/2` compares two full configs, not two files. The first
  # rung's budget is a parameter so the metadata-edit case can move it
  # without moving the selection or the derived rate.
  defp ladder_config(n, rung1_budget \\ 17) do
    dir = Path.join(System.tmp_dir!(), "cairn_srv_ladder_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    File.write!(Path.join(dir, "ladder.yml"), """
    tier: 1
    model_profile: yolox
    model_ladder:
      - model:
          onnx: test/support/fixtures/models/stub.onnx
        input_size: 640
        engine_budget: #{rung1_budget}
      - model:
          onnx: test/support/fixtures/models/stub.onnx
        input_size: 416
        engine_budget: 75
    supported_cameras:
      min: 1
      max: 40
    """)

    from_map!(%{
      "data_dir" => "tmp/cfg_srv_test",
      "profile_dirs" => [dir],
      "plugins" => %{"det" => %{"profile" => "ladder"}},
      "cameras" =>
        Enum.map(1..n//1, fn i ->
          id = "cam_" <> String.pad_leading(Integer.to_string(i), 2, "0")
          %{"id" => id, "rtsp_url" => "rtsp://h/#{i}", "plugin" => "det"}
        end)
    })
  end
end
