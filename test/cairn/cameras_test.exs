defmodule Cairn.CamerasTest do
  # async: false — several describe blocks here start a private,
  # DB-backed Config.Server (see the "writes" setup below).
  use Cairn.DataCase, async: false

  alias Cairn.Cameras
  alias Cairn.Cameras.Camera
  alias Cairn.Cameras.Setting
  alias Cairn.CameraControl
  alias Cairn.CameraStatus
  alias Cairn.Config
  alias Cairn.ConfigSource
  alias Cairn.Event
  alias Cairn.EventCheckpoint
  alias Cairn.Events
  alias Cairn.PresenceCheckpoint

  defp insert!(attrs) do
    Repo.insert!(Camera.changeset(%Camera{}, attrs))
  end

  describe "list/0" do
    test "orders by position" do
      insert!(%{id: "c", position: 2})
      insert!(%{id: "a", position: 0})
      insert!(%{id: "b", position: 1})

      assert Cameras.list() |> Enum.map(& &1.id) == ["a", "b", "c"]
    end
  end

  describe "raw_maps/0" do
    test "renders enabled rows only, in order, with id and zones" do
      yard = %{"id" => "yard", "name" => "Yard", "points" => [[0, 0], [1, 0], [1, 1]]}

      insert!(%{
        id: "cam1",
        position: 0,
        settings: %{"rtsp_url" => "rtsp://cam1"},
        zones: [yard]
      })

      insert!(%{
        id: "cam2",
        position: 1,
        enabled: false,
        settings: %{"rtsp_url" => "rtsp://cam2"}
      })

      insert!(%{id: "cam3", position: 2, settings: %{"rtsp_url" => "rtsp://cam3"}})

      {maps, warnings} = Cameras.raw_maps()

      assert warnings == []
      assert Enum.map(maps, & &1["id"]) == ["cam1", "cam3"]

      assert Enum.at(maps, 0) == %{
               "id" => "cam1",
               "rtsp_url" => "rtsp://cam1",
               "zones" => [yard]
             }

      # A row with no zones renders the empty list, not a missing key.
      assert Enum.at(maps, 1)["zones"] == []
    end

    test "drops an unknown key with exactly one warning and leaves the row unchanged" do
      insert!(%{id: "cam1", position: 0, settings: %{"rtsp_url" => "rtsp://cam1", "udp" => true}})

      {maps, warnings} = Cameras.raw_maps()

      assert warnings == [~s(camera cam1: dropped unknown key "udp")]
      assert Enum.at(maps, 0) == %{"id" => "cam1", "rtsp_url" => "rtsp://cam1", "zones" => []}

      assert Cameras.get("cam1").settings == %{"rtsp_url" => "rtsp://cam1", "udp" => true}
    end
  end

  describe "canonical/1" do
    test "is idempotent" do
      inputs = [
        %{"rtsp_url" => "rtsp://x", "min_score" => 0.5},
        %{"min_score" => %{"person" => 0.4, :car => 0.6}},
        %{"track" => %{"person" => 0.4}, "record" => %{}},
        %{"extra_ffmpeg_args" => "-vf scale=640:480"},
        %{"motion_json" => ~s({"threshold": 30, "enabled": true})},
        %{"motion_json" => "not json"},
        %{"retention" => %{"days" => 7, "per_label" => %{"car" => 30, "person" => nil}}},
        %{"id" => "cam1", "zones" => [%{"name" => "a"}], "rtsp_url" => nil}
      ]

      for input <- inputs do
        once = Cameras.canonical(input)
        twice = Cameras.canonical(once)
        assert twice == once
      end
    end

    test "stringifies keys and drops id, zones, and nil values" do
      result =
        Cameras.canonical(%{id: "cam1", zones: [%{"name" => "a"}], rtsp_url: nil, plugin: "grp"})

      assert result == %{"plugin" => "grp"}
    end

    test "coerces min_score numbers to float maps" do
      assert Cameras.canonical(%{"min_score" => 1}) == %{"min_score" => %{"default" => 1.0}}

      assert Cameras.canonical(%{"min_score" => %{"person" => 1, :car => 0.5}}) ==
               %{"min_score" => %{"person" => 1.0, "car" => 0.5}}
    end

    # `parse_min_score/3` merges what it is given over the default block, so
    # an empty map reads exactly as the absent key — and a row that stored one
    # would diff as an edit the first time the form saved it.
    test "drops an empty min_score map" do
      assert Cameras.canonical(%{"rtsp_url" => "rtsp://h/1", "min_score" => %{}}) ==
               %{"rtsp_url" => "rtsp://h/1"}
    end

    test "coerces track/record tier numbers and drops an empty tier" do
      assert Cameras.canonical(%{"track" => %{"person" => 1}, "record" => %{}}) ==
               %{"track" => %{"person" => %{"min_score" => 1.0}}}
    end

    test "splits a string extra_ffmpeg_args and keeps a list as is" do
      assert Cameras.canonical(%{"extra_ffmpeg_args" => "-vf scale=640:480"}) ==
               %{"extra_ffmpeg_args" => ["-vf", "scale=640:480"]}

      assert Cameras.canonical(%{"extra_ffmpeg_args" => ["-vf", "scale=640:480"]}) ==
               %{"extra_ffmpeg_args" => ["-vf", "scale=640:480"]}
    end

    test "re-encodes motion_json with stable key order regardless of input order" do
      a = Cameras.canonical(%{"motion_json" => ~s({"threshold": 30, "enabled": true})})
      b = Cameras.canonical(%{"motion_json" => ~s({"enabled":true,"threshold":30})})
      assert a == b
    end

    test "keeps an undecodable motion_json verbatim" do
      assert Cameras.canonical(%{"motion_json" => "not json"}) == %{"motion_json" => "not json"}
    end

    # The form has no field that writes any of them, so a row that spelled a
    # default out would read as an edit the first time it was saved.
    test "drops values the parser reads exactly as it reads the absent key" do
      assert Cameras.canonical(%{
               "rtsp_url" => "rtsp://h/1",
               "transcode" => false,
               "extra_ffmpeg_args" => [],
               "pipeline" => "membrane"
             }) == %{"rtsp_url" => "rtsp://h/1"}
    end

    # `parse/3` reads `transcode` as `… == true`, so a string or a number is
    # the default just as `false` is — dropping only `false` would leave a
    # hand-edited `"false"` diffing on every untouched save.
    test "drops every transcode the parser does not read as true" do
      for value <- [false, "false", "no", 0, %{}] do
        assert Cameras.canonical(%{"transcode" => value}) == %{}
      end
    end

    test "keeps a transcode and a pipeline the parser does not read as absent" do
      assert Cameras.canonical(%{"transcode" => true}) == %{"transcode" => true}
      # `check_pipeline/3` refuses this one by name on the next load; repairing
      # it here would hide the key the operator has to delete.
      assert Cameras.canonical(%{"pipeline" => "classic"}) == %{"pipeline" => "classic"}
    end

    test "keeps retention days/per_label, drops nil per-label entries and an empty block" do
      assert Cameras.canonical(%{
               "retention" => %{"days" => 7, "per_label" => %{"car" => 30, "person" => nil}}
             }) == %{"retention" => %{"days" => 7, "per_label" => %{"car" => 30}}}

      assert Cameras.canonical(%{"retention" => %{"per_label" => %{"person" => nil}}}) == %{}
    end
  end

  describe "writes" do
    setup do
      dir = Path.join(System.tmp_dir!(), "cairn_cams_#{System.unique_integer([:positive])}")
      Cairn.DataDir.ensure!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      path = Path.join(dir, "config.yml")
      File.write!(path, "data_dir: #{dir}\n")

      Repo.insert!(
        Setting.changeset(%Setting{}, %{
          key: "yaml_import",
          value: %{"path" => path, "sha256" => String.duplicate("0", 64)}
        })
      )

      test_pid = self()

      server =
        start_supervised!(
          {Config.Server,
           path: path,
           name: nil,
           source: {ConfigSource, :load},
           apply_diff: fn diff, config -> send(test_pid, {:applied, diff, config}) end,
           apply_native: fn _config -> :ok end},
          id: :cameras_write_server
        )

      # `Cairn.Cameras.server/0` reads this env: the writes have to reach the
      # private server, not the application's file-backed singleton.
      Application.put_env(:cairn, :config_server, server)
      on_exit(fn -> Application.delete_env(:cairn, :config_server) end)

      %{dir: dir, server: server}
    end

    test "create, update, reorder, disable and delete round trip", %{server: server} do
      assert {:ok, %{added: ["cam1"]}, []} =
               Cameras.create(%{
                 "id" => "cam1",
                 "settings" => %{"rtsp_url" => "rtsp://h/1", "min_score" => 0.6}
               })

      row = Cameras.get("cam1")
      assert row.position == 0
      assert row.enabled
      # written through `canonical/1`, so the row holds the normalized shape
      assert row.settings == %{"rtsp_url" => "rtsp://h/1", "min_score" => %{"default" => 0.6}}

      assert {:ok, %{added: ["cam2"]}, []} =
               Cameras.create(%{id: "cam2", settings: %{rtsp_url: "rtsp://h/2"}})

      assert Cameras.get("cam2").position == 1

      # D-P5: an untouched re-save renders byte-identically, so it diffs to
      # nothing and no camera restarts.
      assert {:ok, %{added: [], removed: [], changed: [], refreshed: []}, []} =
               Cameras.update("cam1", %{
                 "settings" => %{"rtsp_url" => "rtsp://h/1", "min_score" => 0.6}
               })

      assert {:ok, %{changed: ["cam1"]}, []} =
               Cameras.update("cam1", %{"settings" => %{"rtsp_url" => "rtsp://h/CHANGED"}})

      assert {:ok, %{added: [], removed: [], changed: [], refreshed: []}, []} =
               Cameras.reorder(["cam2", "cam1"])

      assert Enum.map(Cameras.list(), & &1.id) == ["cam2", "cam1"]

      assert {:ok, %{removed: ["cam1"]}, []} = Cameras.set_enabled("cam1", false)
      refute Cameras.get("cam1").enabled
      assert Enum.map(Config.Server.get(server).cameras, & &1.id) == ["cam2"]

      assert {:ok, %{removed: ["cam2"]}, []} = Cameras.delete("cam2")
      assert Cameras.get("cam2") == nil
    end

    test "a row imported with parser-default keys re-saves to an empty diff" do
      imported =
        Cameras.canonical(%{
          "rtsp_url" => "rtsp://h/1",
          "transcode" => false,
          "extra_ffmpeg_args" => [],
          "pipeline" => "membrane"
        })

      assert {:ok, %{added: ["cam1"]}, []} =
               Cameras.create(%{"id" => "cam1", "settings" => imported})

      assert {:ok, %{added: [], removed: [], changed: [], refreshed: []}, []} =
               Cameras.update("cam1", %{"settings" => imported})
    end

    test "reorder refuses any id list that is not the whole fleet, exactly once each" do
      assert {:ok, _diff, []} =
               Cameras.create(%{"id" => "cam1", "settings" => %{"rtsp_url" => "rtsp://h/1"}})

      assert {:ok, _diff, []} =
               Cameras.create(%{"id" => "cam2", "settings" => %{"rtsp_url" => "rtsp://h/2"}})

      # An unknown id, a partial list and a repeat all miss the full set.
      assert Cameras.reorder(["cam1", "nope"]) == {:error, {:write, :incomplete}}
      assert Cameras.reorder(["cam2"]) == {:error, {:write, :incomplete}}
      assert Cameras.reorder(["cam1", "cam1"]) == {:error, {:write, :incomplete}}

      assert Cameras.get("cam1").position == 0
      assert Cameras.get("cam2").position == 1

      assert {:ok, _diff, []} = Cameras.reorder(["cam2", "cam1"])
      assert Cameras.get("cam2").position == 0
      assert Cameras.get("cam1").position == 1
    end

    test "a non-map settings value is a changeset error, not a crash", %{server: server} do
      assert {:error, {:write, %Ecto.Changeset{valid?: false}}} =
               Cameras.create(%{"id" => "cam_bad", "settings" => "nope"})

      refute Cameras.get("cam_bad")
      assert Config.Server.get(server)

      assert {:ok, _diff, []} =
               Cameras.create(%{"id" => "cam1", "settings" => %{"rtsp_url" => "rtsp://h/1"}})

      assert {:error, {:write, %Ecto.Changeset{valid?: false}}} =
               Cameras.update("cam1", %{"settings" => 42})

      assert Config.Server.get(server)
    end

    test "delete prunes status, control and checkpoints" do
      assert {:ok, _diff, []} =
               Cameras.create(%{"id" => "cam1", "settings" => %{"rtsp_url" => "rtsp://h/1"}})

      assert {:ok, _diff, []} =
               Cameras.create(%{"id" => "cam2", "settings" => %{"rtsp_url" => "rtsp://h/2"}})

      CameraStatus.set("cam1", :running)
      CameraStatus.set("cam2", :running)
      # set/2 is a cast; flush it so what the reads below see is the prune's
      # doing and not a write still in flight.
      _flush = :sys.get_state(CameraStatus)
      CameraControl.set("cam1", %{detection_enabled: false})
      event = %Event{id: Ecto.UUID.generate(), camera_id: "cam1", started_at: DateTime.utc_now()}
      PresenceCheckpoint.put("cam1", event, [], nil)
      EventCheckpoint.put("cam1", event)

      assert {:ok, %{removed: ["cam1"]}, []} = Cameras.delete("cam1")

      assert CameraStatus.get("cam1").status == :unknown
      assert CameraStatus.all()["cam2"].status == :running

      assert CameraControl.get("cam1") ==
               %{detection_enabled: true, recording_enabled: true, min_score: nil}

      assert PresenceCheckpoint.get("cam1") == nil
      assert EventCheckpoint.get("cam1") == nil
    end

    # The window a tombstone closes: the HA control endpoint checks the config
    # and then writes, and a delete can commit and prune between the two.
    test "a control write for a deleted camera is refused until the id is re-created" do
      # The control table is a shared singleton the DB sandbox does not roll
      # back; leave "cam1" as the next test expects to find it.
      on_exit(fn -> CameraControl.set("cam1", %{detection_enabled: true}) end)

      assert {:ok, _diff, []} =
               Cameras.create(%{"id" => "cam1", "settings" => %{"rtsp_url" => "rtsp://h/1"}})

      # The overlay the delete's prune drops, and with it the tombstone: an
      # id with nothing in the table is nothing for `prune/1` to name.
      CameraControl.set("cam1", %{detection_enabled: false})

      assert {:ok, _diff, []} = Cameras.delete("cam1")

      assert CameraControl.set("cam1", %{detection_enabled: false}) == {:error, :removed}

      assert {:ok, _diff, []} =
               Cameras.create(%{"id" => "cam1", "settings" => %{"rtsp_url" => "rtsp://h/1"}})

      assert %{detection_enabled: false} = CameraControl.set("cam1", %{detection_enabled: false})
    end

    # A restarting owner exits the call `prune_runtime/1` makes into it; that
    # must not abandon the steps after it while the row delete has already
    # committed. `Cairn.CameraStatus` is a running singleton and not
    # practical to kill mid-test, so this drives `run_prunes/2` directly with
    # a step that exits in the middle of the list.
    test "run_prunes runs every step even when one of them raises" do
      test_pid = self()

      steps = [
        {:first, fn -> send(test_pid, :first) end},
        {:raising, fn -> raise ArgumentError, "table gone" end},
        {:last, fn -> send(test_pid, :last) end}
      ]

      assert [_, {:error, %ArgumentError{}}, _] = Cameras.run_prunes(steps, "cam1")
      assert_received :first
      assert_received :last
    end

    test "run_prunes runs every step even when one of them exits" do
      test_pid = self()

      steps = [
        {"first", fn -> send(test_pid, :first) end},
        {"boom", fn -> exit(:boom) end},
        {"last", fn -> send(test_pid, :last) end}
      ]

      Cameras.run_prunes(steps, "cam1")

      assert_received :first
      assert_received :last
    end

    # D-P8: history outlives the row — the clips and event rows are retention's
    # to sweep, under the id they were recorded with.
    test "a deleted camera's event rows and clips stay", %{dir: dir} do
      assert {:ok, _diff, []} =
               Cameras.create(%{"id" => "cam1", "settings" => %{"rtsp_url" => "rtsp://h/1"}})

      {row, clip} = seed_event(dir, "cam1")

      assert {:ok, %{removed: ["cam1"]}, []} = Cameras.delete("cam1")

      assert Events.get(row.id)
      assert File.exists?(clip)
    end

    test "disabling keeps status and control" do
      assert {:ok, _diff, []} =
               Cameras.create(%{"id" => "cam1", "settings" => %{"rtsp_url" => "rtsp://h/1"}})

      CameraStatus.set("cam1", :running)
      # set/2 is a cast; flush it before the write whose prune must spare it.
      _flush = :sys.get_state(CameraStatus)
      CameraControl.set("cam1", %{detection_enabled: false})

      assert {:ok, %{removed: ["cam1"]}, []} = Cameras.set_enabled("cam1", false)

      assert CameraStatus.get("cam1").status == :running
      assert CameraControl.get("cam1").detection_enabled == false
    end
  end

  defp seed_event(dir, camera_id) do
    id = Ecto.UUID.generate()
    started = DateTime.utc_now()
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
    {row, path}
  end
end
