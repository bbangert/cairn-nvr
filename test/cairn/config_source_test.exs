defmodule Cairn.ConfigSourceTest do
  use Cairn.DataCase, async: false

  @moduletag :capture_log

  alias Cairn.Cameras
  alias Cairn.Cameras.Camera
  alias Cairn.Cameras.Setting
  alias Cairn.Config
  alias Cairn.ConfigSource
  alias Cairn.{Event, Events, Retention}

  @stub_onnx "test/support/fixtures/models/stub.onnx"
  @stub_names "test/support/fixtures/models/stub.names"

  setup do
    dir = Path.join(System.tmp_dir!(), "cairn_src_#{System.unique_integer([:positive])}")
    Cairn.DataDir.ensure!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    %{dir: dir}
  end

  defp write_yaml!(dir, body) do
    path = Path.join(dir, "config.yml")
    File.write!(path, body)
    path
  end

  defp globals(dir, extra \\ "") do
    """
    data_dir: #{dir}
    retention:
      days: 7
    #{extra}
    """
  end

  defp insert_camera!(id, position, settings, opts \\ []) do
    Repo.insert!(
      Camera.changeset(%Camera{}, %{
        id: id,
        position: position,
        enabled: Keyword.get(opts, :enabled, true),
        settings: settings
      })
    )
  end

  # A marker with a sha nothing will match: the tests that pre-write it use a
  # YAML with no `cameras:` key, so drift never looks at it.
  defp mark_imported!(path) do
    Repo.insert!(
      Setting.changeset(%Setting{}, %{
        key: "yaml_import",
        value: %{
          "path" => path,
          "sha256" => String.duplicate("0", 64),
          "imported_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        }
      })
    )
  end

  # Two rungs, no pack rung: a 17-budget accurate rung and the 75-budget
  # capacity rung. On tier 1 (floor 2 fps, cap 10) the fleet size alone moves
  # the derived rate inside rung 1 — 2 cameras derive 10, 3 derive 7.
  defp ladder_dir!(dir, extra_profiles \\ []) do
    profiles = Path.join(dir, "profiles")
    File.mkdir_p!(profiles)

    File.write!(Path.join(profiles, "ladder.yml"), """
    tier: 1
    model_profile: yolox
    labels: #{@stub_names}
    model_ladder:
      - model:
          onnx: #{@stub_onnx}
        input_size: 640
        engine_budget: 17
      - model:
          onnx: #{@stub_onnx}
        input_size: 416
        engine_budget: 75
    supported_cameras: 40
    """)

    Enum.each(extra_profiles, fn {name, body} ->
      File.write!(Path.join(profiles, "#{name}.yml"), body)
    end)

    profiles
  end

  # The single-model profile the ladder agrees with at N=2 and only at N=2.
  @solo_yaml """
  model:
    onnx: #{@stub_onnx}
  model_profile: yolox
  input_size: 640
  labels: #{@stub_names}
  sample_fps: 10
  """

  describe "import" do
    test "the first load imports the YAML cameras once and marks it", %{dir: dir} do
      path =
        write_yaml!(dir, """
        #{globals(dir)}
        cameras:
          - id: cam_a
            rtsp_url: rtsp://h/1
            min_score: 0.6
          - id: cam_b
            rtsp_url: rtsp://h/2
        """)

      assert {:ok, config, warnings, %{}} = ConfigSource.load(path)
      assert Enum.map(config.cameras, & &1.id) == ["cam_a", "cam_b"]

      assert [%{id: "cam_a", position: 0} = row_a, %{id: "cam_b", position: 1}] = Cameras.list()
      assert row_a.enabled
      assert row_a.settings == %{"rtsp_url" => "rtsp://h/1", "min_score" => %{"default" => 0.6}}

      marker = ConfigSource.import_marker()
      assert marker["path"] == path
      assert marker["sha256"] =~ ~r/\A[0-9a-f]{64}\z/
      assert Enum.any?(warnings, &(&1 =~ "still lists cameras:"))

      assert {:ok, config2, _warnings, %{}} = ConfigSource.load(path)
      assert length(Cameras.list()) == 2
      assert ConfigSource.import_marker() == marker
      assert Enum.map(config2.cameras, & &1.id) == ["cam_a", "cam_b"]
    end

    test "a YAML that fails to load imports nothing", %{dir: dir} do
      path =
        write_yaml!(dir, """
        #{globals(dir)}
        cameras:
          - id: cam_a
            rtsp_url: rtsp://h/1
            min_score: 2
        """)

      assert {:error, errors, %Config{cameras: []} = fallback} = ConfigSource.load(path)
      assert Enum.any?(errors, &(&1 =~ "camera cam_a: min_score values must be 0..1"))
      assert Cameras.list() == []
      assert ConfigSource.import_marker() == nil

      # The operator's globals, not the struct defaults: what Retention and
      # the HA token run on until the file is fixed.
      assert fallback.retention_days == 7
      assert fallback.data_dir == dir
    end

    test "removing the cameras key after the import is quiet", %{dir: dir} do
      body = """
      #{globals(dir)}
      cameras:
        - id: cam_a
          rtsp_url: rtsp://h/1
      """

      path = write_yaml!(dir, body)
      assert {:ok, _config, _warnings, %{}} = ConfigSource.load(path)

      File.write!(path, globals(dir))

      assert {:ok, config, warnings, %{}} = ConfigSource.load(path)
      assert Enum.map(config.cameras, & &1.id) == ["cam_a"]
      refute Enum.any?(warnings, &(&1 =~ "still lists cameras" or &1 =~ "changed since"))
    end

    test "cameras edited in the YAML after the import warn to re-import", %{dir: dir} do
      path =
        write_yaml!(dir, """
        #{globals(dir)}
        cameras:
          - id: cam_a
            rtsp_url: rtsp://h/1
        """)

      assert {:ok, _config, _warnings, %{}} = ConfigSource.load(path)

      File.write!(path, """
      #{globals(dir)}
      cameras:
        - id: cam_a
          rtsp_url: rtsp://h/9
      """)

      assert {:ok, _config, warnings, %{}} = ConfigSource.load(path)
      assert Enum.any?(warnings, &(&1 =~ "cameras changed since they were imported"))
      assert Cameras.get("cam_a").settings["rtsp_url"] == "rtsp://h/1"
    end

    test "an unknown key on the imported YAML camera is dropped, warned once, and not stored",
         %{dir: dir} do
      path =
        write_yaml!(dir, """
        #{globals(dir)}
        cameras:
          - id: cam_a
            rtsp_url: rtsp://h/1
            udp: 1
        """)

      assert {:ok, _config, warnings, %{}} = ConfigSource.load(path)
      assert Enum.count(warnings, &(&1 == ~s(camera cam_a: dropped unknown key "udp"))) == 1
      assert Cameras.get("cam_a").settings == %{"rtsp_url" => "rtsp://h/1"}

      assert {:ok, _config, warnings2, %{}} = ConfigSource.load(path)
      refute Enum.any?(warnings2, &(&1 =~ "unknown key"))
    end

    test "a YAML camera's zones earn their own warning, not the unknown-key one", %{dir: dir} do
      path =
        write_yaml!(dir, """
        #{globals(dir)}
        cameras:
          - id: cam_a
            rtsp_url: rtsp://h/1
            zones:
              - name: drive
                points: [[0, 0], [1, 0], [1, 1]]
        """)

      assert {:ok, _config, warnings, %{}} = ConfigSource.load(path)
      assert Enum.any?(warnings, &(&1 =~ "camera cam_a: zones are not imported"))
      refute Enum.any?(warnings, &(&1 =~ ~s(dropped unknown key "zones")))
      assert Cameras.get("cam_a").zones == []
    end

    test "a first boot without a cameras key still arms the import latch", %{dir: dir} do
      path = write_yaml!(dir, globals(dir))

      assert {:ok, _config, _warnings, %{}} = ConfigSource.load(path)
      # The sha of `[]`, so a `cameras:` key added later reads as drift and
      # never re-enters the importer.
      assert marker = ConfigSource.import_marker()
      assert marker["sha256"] =~ ~r/\A[0-9a-f]{64}\z/

      File.write!(path, """
      #{globals(dir)}
      cameras:
        - id: cam_a
          rtsp_url: rtsp://h/1
      """)

      assert {:ok, config, warnings, %{}} = ConfigSource.load(path)
      assert Enum.any?(warnings, &(&1 =~ "cameras changed since they were imported"))
      assert Cameras.list() == []
      assert config.cameras == []
      assert ConfigSource.import_marker() == marker
    end

    test "rows that exist before any marker are never overwritten by a YAML import", %{dir: dir} do
      insert_camera!("cam_a", 0, %{"rtsp_url" => "rtsp://rows/1"})

      path =
        write_yaml!(dir, """
        #{globals(dir)}
        cameras:
          - id: cam_a
            rtsp_url: rtsp://yaml/1
        """)

      assert {:ok, config, warnings, %{}} = ConfigSource.load(path)
      assert [%Config.Camera{id: "cam_a", rtsp_url: "rtsp://rows/1"}] = config.cameras
      assert Cameras.get("cam_a").settings["rtsp_url"] == "rtsp://rows/1"
      assert ConfigSource.import_marker()

      assert Enum.any?(
               warnings,
               &(&1 =~ "cameras were not imported — the database already has rows")
             )
    end

    test "an empty cameras list arms the latch and warns about nothing", %{dir: dir} do
      path = write_yaml!(dir, globals(dir) <> "cameras: []\n")

      assert {:ok, _config, warnings, %{}} = ConfigSource.load(path)
      assert ConfigSource.import_marker()
      refute Enum.any?(warnings, &(&1 =~ ~r/lists cameras|changed since/))

      assert {:ok, _config, warnings2, %{}} = ConfigSource.load(path)
      refute Enum.any?(warnings2, &(&1 =~ ~r/lists cameras|changed since/))
    end
  end

  describe "render" do
    test "an unknown key in a row is dropped at render with one warning and never reaches from_map",
         %{dir: dir} do
      path = write_yaml!(dir, globals(dir))
      mark_imported!(path)
      insert_camera!("cam_a", 0, %{"rtsp_url" => "rtsp://h/1", "udp" => 1})

      assert {:ok, _config, warnings, %{}} = ConfigSource.load(path)
      assert Enum.count(warnings, &(&1 =~ "dropped unknown key")) == 1
      # The parser's own forms, which would mean the key reached `from_map/1`.
      refute Enum.any?(warnings, &(&1 =~ ~r/unknown key "udp" in|camera cam_a: unknown key/))
    end

    test "a disabled row is not rendered and does not warn", %{dir: dir} do
      path = write_yaml!(dir, globals(dir))
      mark_imported!(path)
      insert_camera!("cam_a", 0, %{"rtsp_url" => "rtsp://h/1"})
      insert_camera!("cam_b", 1, %{"pipeline" => "classic"}, enabled: false)

      assert {:ok, config, warnings, %{}} = ConfigSource.load(path)
      assert Enum.map(config.cameras, & &1.id) == ["cam_a"]
      refute Enum.any?(warnings, &(&1 =~ "cam_b"))
      assert [%Config.Camera{id: "cam_b"}] = config.dormant
    end
  end

  describe "skip" do
    test "one invalid row does not blank the fleet", %{dir: dir} do
      path = write_yaml!(dir, globals(dir))
      mark_imported!(path)
      insert_camera!("cam_a", 0, %{"rtsp_url" => "rtsp://h/1"})

      insert_camera!("cam_b", 1, %{
        "rtsp_url" => "rtsp://h/2",
        "pipeline" => "classic",
        "retention" => %{"days" => 90}
      })

      assert {:ok, config, warnings, skipped} = ConfigSource.load(path)
      assert [%Config.Camera{id: "cam_a"}] = config.cameras
      assert %{"cam_b" => [error]} = skipped
      assert error =~ "classic pipeline was removed"

      assert Enum.any?(warnings, fn w ->
               w =~ "camera cam_b: skipped — " and w =~ "classic pipeline was removed"
             end)

      assert config.dormant == [
               %Config.Camera{id: "cam_b", retention_days: 90, retention_per_label: %{}}
             ]
    end

    test "a fleet-level error still fails the load even with a skippable row", %{dir: dir} do
      path =
        write_yaml!(dir, """
        #{globals(dir)}
        profile_dirs:
          - test/support/fixtures/profiles/argv
        plugins:
          full:
            profile: full
          partial:
            profile: partial
        """)

      mark_imported!(path)
      insert_camera!("cam_a", 0, %{"rtsp_url" => "rtsp://h/1", "plugin" => "full"})
      insert_camera!("cam_b", 1, %{"rtsp_url" => "rtsp://h/2", "plugin" => "partial"})
      insert_camera!("cam_c", 2, %{"rtsp_url" => "rtsp://h/3", "pipeline" => "classic"})

      assert {:error, errors, fallback} = ConfigSource.load(path)
      assert Enum.any?(errors, &(&1 =~ "different models (full, partial)"))
      assert Enum.any?(errors, &(&1 =~ "camera cam_c: the classic pipeline was removed"))

      # The fallback carries the YAML globals and every row as dormant: with
      # no cameras loaded, a row's own retention override is the only thing
      # keeping its clips off the global clock.
      assert fallback.cameras == []
      assert fallback.retention_days == 7
      assert fallback.data_dir == dir
      assert Enum.map(fallback.dormant, & &1.id) == ["cam_a", "cam_b", "cam_c"]
    end

    test "a skip whose held N cannot make the fleet agree is refused", %{dir: dir} do
      profiles = ladder_dir!(dir, solo: @solo_yaml)

      path =
        write_yaml!(dir, """
        #{globals(dir)}
        profile_dirs:
          - #{profiles}
        plugins:
          det:
            profile: ladder
          solo:
            profile: solo
        """)

      mark_imported!(path)
      insert_camera!("cam_a", 0, %{"rtsp_url" => "rtsp://h/1", "plugin" => "det"})
      insert_camera!("cam_b", 1, %{"rtsp_url" => "rtsp://h/2", "plugin" => "solo"})

      broken = %{
        "rtsp_url" => "rtsp://h/3",
        "plugin" => "det",
        "annotation_offset_ms" => "x"
      }

      cam_c = insert_camera!("cam_c", 2, broken)

      # The fleet is three detecting cameras whatever cam_c's own fault is:
      # the ladder lowers to 7 fps while solo stays pinned at 10, so the load
      # is refused with cam_c's error beside the disagreement. Dropping cam_c
      # to N=2 would make the two agree — the skip is not allowed to buy that.
      assert {:error, errors, _fallback} = ConfigSource.load(path)

      assert Enum.any?(
               errors,
               &(&1 =~ "camera cam_c: annotation_offset_ms must be an integer number of ms")
             )

      assert Enum.any?(errors, &(&1 =~ "different models (ladder, solo)"))

      # Positive controls: the refusal is the held N, not a broken fixture.
      # Three valid cameras disagree the same way at the real N=3 …
      cam_c =
        Repo.update!(
          Camera.update_changeset(cam_c, %{
            settings: Map.delete(broken, "annotation_offset_ms")
          })
        )

      assert {:error, errors3, _fallback} = ConfigSource.load(path)
      assert Enum.any?(errors3, &(&1 =~ "different models (ladder, solo)"))

      # … and two agree.
      Repo.delete!(cam_c)
      assert {:ok, config, _warnings, %{}} = ConfigSource.load(path)
      assert Enum.map(config.cameras, & &1.id) == ["cam_a", "cam_b"]
    end

    test "a skip that would shrink N into a disagreement loads on the held N", %{dir: dir} do
      # Spike §2(a) step 3, resolved by the hold: four detecting cameras put
      # the ladder at 4 fps, which is what solo is pinned to. Skipping cam_d
      # on the real N=3 would raise the ladder to 7 and refuse the whole
      # load; the held N=4 keeps them agreeing, which is why the pass-2 error
      # branch is a backstop rather than the working path.
      profiles =
        ladder_dir!(dir,
          solo: """
          model:
            onnx: #{@stub_onnx}
          model_profile: yolox
          input_size: 640
          labels: #{@stub_names}
          sample_fps: 4
          """
        )

      path =
        write_yaml!(dir, """
        #{globals(dir)}
        profile_dirs:
          - #{profiles}
        plugins:
          det:
            profile: ladder
          solo:
            profile: solo
        """)

      mark_imported!(path)
      insert_camera!("cam_a", 0, %{"rtsp_url" => "rtsp://h/1", "plugin" => "det"})
      insert_camera!("cam_b", 1, %{"rtsp_url" => "rtsp://h/2", "plugin" => "det"})
      insert_camera!("cam_c", 2, %{"rtsp_url" => "rtsp://h/3", "plugin" => "solo"})

      insert_camera!("cam_d", 3, %{
        "rtsp_url" => "rtsp://h/4",
        "plugin" => "det",
        "annotation_offset_ms" => "x"
      })

      assert {:ok, config, _warnings, %{"cam_d" => _errors}} = ConfigSource.load(path)
      assert Enum.map(config.cameras, & &1.id) == ["cam_a", "cam_b", "cam_c"]
      assert Config.sample_fps(config, hd(config.cameras)) == 4
    end

    test "a skip holds N so survivors do not restart", %{dir: dir} do
      profiles = ladder_dir!(dir)

      path =
        write_yaml!(dir, """
        #{globals(dir)}
        profile_dirs:
          - #{profiles}
        plugins:
          det:
            profile: ladder
        """)

      mark_imported!(path)
      insert_camera!("cam_a", 0, %{"rtsp_url" => "rtsp://h/1", "plugin" => "det"})
      insert_camera!("cam_b", 1, %{"rtsp_url" => "rtsp://h/2", "plugin" => "det"})
      cam_c = insert_camera!("cam_c", 2, %{"rtsp_url" => "rtsp://h/3", "plugin" => "det"})

      server = private_server(path)

      config = Config.Server.get(server)
      assert Config.sample_fps(config, hd(config.cameras)) == 7

      Repo.update!(
        Camera.update_changeset(cam_c, %{
          settings: %{
            "rtsp_url" => "rtsp://h/3",
            "plugin" => "det",
            "annotation_offset_ms" => "x"
          }
        })
      )

      assert {:ok, diff, warnings} = Config.Server.reload(server)
      # Without the hold the reduced N=2 would derive 10 fps, putting cam_a
      # and cam_b in `changed` — a repair that restarts the cameras beside it.
      assert diff == %{added: [], changed: [], refreshed: [], removed: ["cam_c"]}
      assert Enum.any?(warnings, &(&1 =~ "camera cam_c: skipped — "))

      after_skip = Config.Server.get(server)
      assert Config.sample_fps(after_skip, hd(after_skip.cameras)) == 7
      assert Map.has_key?(Config.Server.last_load(server).skipped, "cam_c")
    end
  end

  describe "retention" do
    test "a skipped or disabled camera's clips keep its retention override", %{dir: dir} do
      path = write_yaml!(dir, globals(dir))
      mark_imported!(path)
      insert_camera!("cam_a", 0, %{"rtsp_url" => "rtsp://h/1"})

      insert_camera!("cam_b", 1, %{"rtsp_url" => "rtsp://h/2", "retention" => %{"days" => 90}},
        enabled: false
      )

      insert_camera!("cam_c", 2, %{
        "rtsp_url" => "rtsp://h/3",
        "pipeline" => "classic",
        "retention" => %{"days" => 90}
      })

      server = private_server(path)

      ret =
        start_supervised!(
          {Retention,
           name: nil,
           manual: true,
           config_fun: fn -> Config.Server.get(server) end,
           free_space_fun: fn _dir -> {:ok, 500 * 1024 * 1024} end},
          id: :retention_dormant
        )

      kept_b = seed_event(dir, "cam_b", 30)
      kept_c = seed_event(dir, "cam_c", 30)
      swept_a = seed_event(dir, "cam_a", 30)

      send(ret, :prune)
      # `alert/1` is a call on the same process: it returns only once the
      # prune message ahead of it has been handled.
      _ = Retention.alert(ret)

      assert Events.get(kept_b.id)
      assert Events.get(kept_c.id)
      refute Events.get(swept_a.id)
    end

    test "a dormant row's non-integer per_label days are dropped, not carried into the sweep",
         %{dir: dir} do
      path = write_yaml!(dir, globals(dir))
      mark_imported!(path)
      insert_camera!("cam_a", 0, %{"rtsp_url" => "rtsp://h/1"})

      insert_camera!(
        "cam_b",
        1,
        %{"rtsp_url" => "rtsp://h/2", "retention" => %{"per_label" => %{"person" => "7"}}},
        enabled: false
      )

      assert {:ok, config, _warnings, %{}} = ConfigSource.load(path)
      assert [%Config.Camera{id: "cam_b", retention_per_label: %{}}] = config.dormant

      seed_event(dir, "cam_b", 30)
      # The unguarded string would raise inside `Enum.max` here.
      assert is_integer(Retention.run_prune(config))
    end
  end

  defp private_server(path) do
    test_pid = self()

    start_supervised!(
      {Config.Server,
       path: path,
       name: nil,
       source: {ConfigSource, :load},
       apply_diff: fn diff, config -> send(test_pid, {:applied, diff, config}) end,
       apply_native: fn config -> send(test_pid, {:native_applied, config}) end},
      id: :config_source_server
    )
  end

  defp seed_event(dir, camera_id, days_ago) do
    id = Ecto.UUID.generate()
    started = DateTime.add(DateTime.utc_now(), -days_ago * 86_400)
    path = Cairn.DataDir.event_clip_path(dir, camera_id, id, DateTime.to_unix(started))
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "clip")

    event = %Event{
      id: id,
      camera_id: camera_id,
      started_at: started,
      max_scores: %{"car" => 0.9}
    }

    {:ok, _row} = Events.create_active(event, path)
    {:ok, row} = Events.finalize(%{event | ended_at: started, status: :finalized}, 4)
    row
  end
end
