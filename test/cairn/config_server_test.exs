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
    # the file source skips no camera: it errors on the whole file instead
    assert Config.Server.last_load(server) == %{warnings: [], errors: [], skipped: %{}}
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

    # `server` is the pid because this one is unnamed: the tag is what an
    # owner filters a shared-topic broadcast on (`t:Cairn.Config.Server.diff/0`),
    # and `known` is the fleet as of this version, which is what it prunes to.
    assert diff == %{
             added: ["cam_c"],
             removed: ["cam_b"],
             changed: ["cam_a"],
             refreshed: [],
             version: 2,
             server: server,
             known: MapSet.new(["cam_a", "cam_c"])
           }

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
            %{"retention" => %{"days" => 3}},
            # Render-time only: nothing in a running pipeline reads it, so
            # tuning it must never cost a camera its stream.
            %{"annotation_offset_ms" => -250}
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
      # The rate is baked into the branch at build time (the decoder's
      # SampleGate opens on it, a frame-counting core sizes its lost-track
      # buffer from it), and it is a profile field alone — a camera's own
      # struct does not move when it changes.
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

  test "a failed reload carries only its own errors", %{server: server, path: path, dir: dir} do
    File.write!(path, """
    data_dir: #{Path.join(dir, "data")}
    shenanigans: 1
    cameras:
      - id: cam_a
        rtsp_url: rtsp://h/1
    """)

    assert {:ok, _diff, [_ | _]} = Config.Server.reload(server)
    assert %{warnings: [warning], errors: [], skipped: %{}} = Config.Server.last_load(server)
    assert warning =~ ~s(unknown key "shenanigans")

    File.write!(path, "cameras: [{id: cam_a}]\n")
    assert {:error, _errors} = Config.Server.reload(server)

    # the warning above described a file that is gone; only the errors of the
    # attempt that failed survive
    assert %{warnings: [], errors: [_ | _], skipped: %{}} = Config.Server.last_load(server)
  end

  test "reload loads through the injected source, not the file", %{dir: dir, path: path} do
    test_pid = self()

    injected =
      from_map!(%{
        "data_dir" => Path.join(dir, "data"),
        "cameras" => [%{"id" => "cam_z", "rtsp_url" => "rtsp://h/z"}]
      })

    source = fn loaded ->
      send(test_pid, {:source, loaded})
      {:ok, injected, [], %{}}
    end

    server =
      start_supervised!(
        {Config.Server,
         path: path,
         name: nil,
         source: source,
         apply_diff: fn _diff, _config -> :ok end,
         apply_native: fn _config -> :ok end},
        id: :injected_source_server
      )

    assert_received {:source, ^path}
    # the file at `path` holds cam_a/cam_b; nothing read it
    assert [%{id: "cam_z"}] = Config.Server.get(server).cameras

    assert {:ok, %{added: [], removed: [], changed: [], refreshed: []}, []} =
             Config.Server.reload(server)

    assert_received {:source, ^path}
  end

  @tag :capture_log
  test "a failed boot keeps data_dir, retention and the HA token from the YAML", %{dir: dir} do
    path = Path.join(dir, "camera_fault.yml")
    # A distinct dir from the harness's, so the assertion below discriminates:
    # nothing else has ensured it.
    data_dir = Path.join(dir, "fallback")

    File.write!(path, """
    data_dir: #{data_dir}
    retention:
      days: 30
    integrations:
      token: yaml-token
    cameras:
      - id: cam_a
    """)

    server =
      start_supervised!(
        {Config.Server,
         path: path,
         name: nil,
         apply_diff: fn _diff, _config -> :ok end,
         apply_native: fn _config -> :ok end},
        id: :failed_boot_server
      )

    config = Config.Server.get(server)
    assert config.data_dir == data_dir
    assert config.retention_days == 30
    assert config.ha_token == "yaml-token"
    assert config.cameras == []

    assert Enum.any?(Config.Server.last_load(server).errors, &(&1 =~ "rtsp_url is required"))
    # the readers that run regardless got the operator's dir, not the struct
    # default's cwd "data"
    assert File.dir?(Path.join(data_dir, "log"))
  end

  @tag :capture_log
  test "a file whose globals are invalid installs no half-built fallback", %{dir: dir} do
    path = Path.join(dir, "bad_globals.yml")

    # Both halves are broken, so `globals_fallback/1` fails its own
    # re-validation and there is nothing between the file and `%Config{}`.
    File.write!(path, """
    data_dir: 42
    cameras:
      - id: cam_a
    """)

    server =
      start_supervised!(
        {Config.Server,
         path: path,
         name: nil,
         apply_diff: fn _diff, _config -> :ok end,
         apply_native: fn _config -> :ok end},
        id: :bad_globals_server
      )

    config = Config.Server.get(server)
    assert config.cameras == []
    assert config.retention_days == 14

    errors = Config.Server.last_load(server).errors
    assert Enum.any?(errors, &(&1 =~ "data_dir must be a string"))
    assert Enum.any?(errors, &(&1 =~ "rtsp_url is required"))
  end

  @tag :capture_log
  test "a missing file boots with the defaults and says so", %{dir: dir} do
    server =
      start_supervised!(
        {Config.Server,
         path: Path.join(dir, "missing.yml"),
         name: nil,
         apply_diff: fn _diff, _config -> :ok end,
         apply_native: fn _config -> :ok end},
        id: :missing_file_server
      )

    assert Config.Server.get(server).cameras == []
    assert Enum.any?(Config.Server.last_load(server).errors, &(&1 =~ "cannot read config"))
  end

  test "an unnamed server publishes no snapshot", %{path: path} do
    production = Config.Server.snapshot_key(Config.Server)
    before = :persistent_term.get(production, :none)

    start_supervised!(
      {Config.Server,
       path: path,
       name: nil,
       apply_diff: fn _diff, _config -> :ok end,
       apply_native: fn _config -> :ok end},
      id: :unnamed_snapshot_server
    )

    assert :persistent_term.get(Config.Server.snapshot_key(nil), :none) == :none
    # and the application's own snapshot is untouched by an unnamed boot
    assert :persistent_term.get(production, :none) == before
  end

  test "a non-atom name is refused", %{path: path} do
    assert_raise ArgumentError, fn ->
      Config.Server.start_link(path: path, name: {:via, Registry, {Cairn.Registry, :y}})
    end
  end

  @tag :capture_log
  test "a malformed loader is refused at boot", %{path: path} do
    Process.flag(:trap_exit, true)

    assert {:error, {%ArgumentError{message: msg}, _stack}} =
             Config.Server.start_link(path: path, name: nil, source: "nope")

    assert msg =~ ":config_loader"
  end

  @tag :capture_log
  test "a source answering the wrong shape is refused", %{path: path} do
    Process.flag(:trap_exit, true)

    assert {:error, {%ArgumentError{message: msg}, _stack}} =
             Config.Server.start_link(path: path, name: nil, source: fn _path -> {:ok, :nope} end)

    assert msg =~ "expected {:ok, %Cairn.Config{}"
  end

  test "the snapshot is published before apply_diff runs", %{dir: dir, path: path} do
    test_pid = self()
    name = :"snap_test_#{System.unique_integer([:positive])}"
    on_exit(fn -> :persistent_term.erase(Config.Server.snapshot_key(name)) end)

    # apply_diff runs inside the server; a tree started from it must find the
    # NEW fleet, so the snapshot has to be published by the time it runs
    apply_diff = fn _diff, _config ->
      send(test_pid, {:seen, Config.Server.snapshot_camera("cam_c", name)})
    end

    server =
      start_supervised!(
        {Config.Server,
         path: path, name: name, apply_diff: apply_diff, apply_native: fn _config -> :ok end},
        id: :snapshot_server
      )

    assert {:ok, %Config.Camera{id: "cam_a"}, %Config{}} =
             Config.Server.snapshot_camera("cam_a", name)

    File.write!(path, """
    data_dir: #{Path.join(dir, "data")}
    cameras:
      - id: cam_c
        rtsp_url: rtsp://h/3
    """)

    assert {:ok, _diff, []} = Config.Server.reload(server)

    assert_received {:seen, {:ok, %Config.Camera{id: "cam_c"}, %Config{}}}
    assert Config.Server.snapshot_camera("cam_b", name) == :error
  end

  test "a failed reload leaves the snapshot on the old fleet", %{path: path} do
    name = :"snap_stale_#{System.unique_integer([:positive])}"
    on_exit(fn -> :persistent_term.erase(Config.Server.snapshot_key(name)) end)

    server =
      start_supervised!(
        {Config.Server,
         path: path,
         name: name,
         apply_diff: fn _diff, _config -> :ok end,
         apply_native: fn _config -> :ok end},
        id: :snapshot_stale_server
      )

    File.write!(path, "cameras: [{id: cam_a}]\n")
    assert {:error, _errors} = Config.Server.reload(server)

    assert {:ok, %Config.Camera{id: "cam_a"}, %Config{}} =
             Config.Server.snapshot_camera("cam_a", name)
  end

  describe "version" do
    test "the boot install is version 1", %{server: server} do
      assert Config.Server.get(server).version == 1
    end

    test "every applied reload increments it, on the config and in the diff", %{
      server: server,
      path: path,
      dir: dir
    } do
      File.write!(path, """
      data_dir: #{Path.join(dir, "data")}
      cameras:
        - id: cam_a
          rtsp_url: rtsp://h/1
      """)

      assert {:ok, %{version: 2}, []} = Config.Server.reload(server)
      assert Config.Server.get(server).version == 2

      assert {:ok, %{version: 3}, []} = Config.Server.reload(server)
      assert Config.Server.get(server).version == 3
    end

    test "a reload that installs nothing leaves it alone", %{server: server, path: path} do
      File.write!(path, "cameras: [{id: cam_a}]\n")

      assert {:error, _errors} = Config.Server.reload(server)
      assert Config.Server.get(server).version == 1
    end

    # The term outlives the process, so a restarted server continues the count:
    # restarting at 1 would re-accept a pin the old server had already spent.
    test "a boot seeds it from the surviving snapshot", %{path: path} do
      name = :"version_seed_#{System.unique_integer([:positive])}"
      key = Config.Server.snapshot_key(name)
      on_exit(fn -> :persistent_term.erase(key) end)
      :persistent_term.put(key, %Config{version: 7})

      server = named_server(path, name, :version_seed_server)

      assert Config.Server.get(server).version == 8
      assert %Config{version: 8} = Config.Server.snapshot(name)
    end

    # The owners prune on the broadcast against the published snapshot, so the
    # publish has to be the older of the two. The apply callback runs between
    # them, and reads the term while the server is still inside the apply.
    test "the snapshot is published before the broadcast", %{path: path, dir: dir} do
      name = :"publish_first_#{System.unique_integer([:positive])}"
      on_exit(fn -> :persistent_term.erase(Config.Server.snapshot_key(name)) end)
      test_pid = self()

      server =
        start_supervised!(
          {Config.Server,
           path: path,
           name: name,
           apply_diff: fn diff, _config ->
             send(
               test_pid,
               {:snapshot_at_apply, Config.Server.snapshot(name).version, diff.version}
             )
           end,
           apply_native: fn _config -> :ok end},
          id: :publish_first_server
        )

      Config.Server.subscribe()

      File.write!(path, """
      data_dir: #{Path.join(dir, "data")}
      cameras:
        - id: cam_a
          rtsp_url: rtsp://h/1
      """)

      assert {:ok, _diff, []} = Config.Server.reload(server)

      assert_receive {:snapshot_at_apply, version, version}
      assert_receive {:config_changed, diff}
      assert diff.version == version
      assert diff.server == name
    end

    test "the published snapshot carries it", %{path: path} do
      name = :"version_snap_#{System.unique_integer([:positive])}"
      on_exit(fn -> :persistent_term.erase(Config.Server.snapshot_key(name)) end)

      server = named_server(path, name, :version_snapshot_server)

      assert %Config{version: 1} = Config.Server.snapshot(name)
      assert {:ok, _diff, []} = Config.Server.reload(server)
      assert %Config{version: 2} = Config.Server.snapshot(name)
    end
  end

  describe "snapshot/1 and known_ids/1" do
    test "both answer nil for a server that has published nothing" do
      name = :"never_published_#{System.unique_integer([:positive])}"

      assert Config.Server.snapshot(name) == nil
      assert Config.Server.known_ids(name) == nil
    end

    # A disabled or skipped row is dormant, not gone: an owner that pruned it
    # would drop the state of a camera the operator can switch back on.
    test "known_ids counts the dormant rows too", %{path: path} do
      name = :"known_ids_#{System.unique_integer([:positive])}"
      on_exit(fn -> :persistent_term.erase(Config.Server.snapshot_key(name)) end)

      config = camera_config([%{"id" => "cam_a", "rtsp_url" => "rtsp://h/1"}], %{})

      source = fn _path ->
        {:ok, %{config | dormant: [%Config.Camera{id: "cam_off"}]}, [], %{}}
      end

      start_supervised!(
        {Config.Server,
         path: path,
         name: name,
         source: source,
         apply_diff: fn _diff, _config -> :ok end,
         apply_native: fn _config -> :ok end},
        id: :known_ids_server
      )

      assert Config.Server.known_ids(name) == MapSet.new(["cam_a", "cam_off"])
    end

    # The owners prune against `diff.known` rather than the moving snapshot,
    # so the two must agree camera for camera at the version that produced it
    # — dormant rows included.
    test "the diff's known is the version's own known_ids, dormant included", %{path: path} do
      name = :"diff_known_#{System.unique_integer([:positive])}"
      on_exit(fn -> :persistent_term.erase(Config.Server.snapshot_key(name)) end)

      config = camera_config([%{"id" => "cam_a", "rtsp_url" => "rtsp://h/1"}], %{})

      source = fn _path ->
        {:ok, %{config | dormant: [%Config.Camera{id: "cam_off"}]}, [], %{}}
      end

      server =
        start_supervised!(
          {Config.Server,
           path: path,
           name: name,
           source: source,
           apply_diff: fn _diff, _config -> :ok end,
           apply_native: fn _config -> :ok end},
          id: :diff_known_server
        )

      assert {:ok, diff, []} = Config.Server.reload(server)
      assert diff.known == MapSet.new(["cam_a", "cam_off"])
      assert diff.known == Config.Server.known_ids(name)
    end
  end

  describe "would_restart?/3" do
    test "an edit that reaches a subprocess would restart the camera" do
      assert would_restart?(%{"rtsp_url" => "rtsp://h/CHANGED"})
    end

    test "a host-side edit would not" do
      refute would_restart?(%{"post_window_seconds" => 42})
    end

    # Resolved configs, not raw settings: a global the camera does not
    # override moves it too.
    test "a global the camera resolves through would restart it" do
      assert would_restart?(%{}, %{"events" => %{"pre_window_seconds" => 9}})
    end

    test "an added or removed camera is not a restart" do
      one = camera_config([%{"id" => "cam_a", "rtsp_url" => "rtsp://h/1"}], %{})
      none = camera_config([], %{})

      refute Config.Server.would_restart?(none, one, "cam_a")
      refute Config.Server.would_restart?(one, none, "cam_a")
      refute Config.Server.would_restart?(one, one, "cam_absent")
    end
  end

  defp would_restart?(edit, global \\ %{}) do
    base = %{"id" => "cam_a", "rtsp_url" => "rtsp://h/1"}

    Config.Server.would_restart?(
      camera_config([base], %{}),
      camera_config([Map.merge(base, edit)], global),
      "cam_a"
    )
  end

  defp named_server(path, name, id) do
    start_supervised!(
      {Config.Server,
       path: path,
       name: name,
       apply_diff: fn _diff, _config -> :ok end,
       apply_native: fn _config -> :ok end},
      id: id
    )
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
    supported_cameras: 40
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
