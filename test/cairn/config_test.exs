defmodule Cairn.ConfigTest do
  use ExUnit.Case, async: true

  alias Cairn.Config

  @valid_fixture "test/support/fixtures/configs/valid.yml"
  @groups_fixture "test/support/fixtures/configs/plugin_groups.yml"

  defp base_map do
    %{
      "data_dir" => "tmp/cfg_test",
      "cameras" => [
        %{"id" => "cam_a", "rtsp_url" => "rtsp://h/1"},
        %{"id" => "cam_b", "rtsp_url" => "rtsp://h/2"}
      ]
    }
  end

  defp camera_retention_map(retention) do
    Map.put(base_map(), "cameras", [
      %{"id" => "cam_a", "rtsp_url" => "rtsp://h/1", "retention" => retention}
    ])
  end

  describe "load/1" do
    test "loads the valid fixture" do
      assert {:ok, %Config{} = config, warnings} = Config.load(@valid_fixture)
      assert config.stall_seconds == 15

      assert [
               %Config.Camera{id: "cam_a"} = cam_a,
               %Config.Camera{id: "cam_b"},
               %Config.Camera{id: "cam_dual", substream_url: "rtsp://127.0.0.1:8554/d_sub"}
             ] = config.cameras

      assert cam_a.min_score == %{"default" => 0.5, "person" => 0.6}
      assert Enum.empty?(warnings)
    end

    test "missing file is an error" do
      assert {:error, [msg]} = Config.load("nope/missing.yml")
      assert msg =~ "cannot read config"
    end

    test "non-mapping yaml is an error" do
      path = tmp_yaml("- just\n- a list\n")
      assert {:error, ["config must be a YAML mapping"]} = Config.load(path)
    end
  end

  describe "from_map/1 validation" do
    test "valid map with defaults applied" do
      assert {:ok, config, []} = Config.from_map(base_map())
      assert config.pre_window_seconds == 5
      assert config.retention_days == 14
      assert length(config.cameras) == 2
    end

    test "remux_clips defaults on and accepts an explicit opt-out" do
      assert {:ok, config, []} = Config.from_map(base_map())
      assert config.remux_clips == true

      assert {:ok, off, []} = Config.from_map(Map.put(base_map(), "remux_clips", false))
      assert off.remux_clips == false
    end

    test "non-boolean remux_clips is an error" do
      map = Map.put(base_map(), "remux_clips", "yes")
      assert {:error, errors} = Config.from_map(map)
      assert Enum.any?(errors, &(&1 =~ "remux_clips must be true or false"))
    end

    test "a leftover udp: block from before phase 6 is a warning, not an error" do
      map = Map.put(base_map(), "udp", %{"base_port" => 17_000, "range" => 20})

      assert {:ok, _config, warnings} = Config.from_map(map)
      assert Enum.any?(warnings, &(&1 =~ ~s(unknown key "udp" in config)))
    end

    test "bad windows are errors" do
      map =
        Map.put(base_map(), "events", %{
          "pre_window_seconds" => -1,
          "post_window_seconds" => 0,
          "max_event_seconds" => 1
        })

      assert {:error, errors} = Config.from_map(map)
      assert Enum.any?(errors, &(&1 =~ "pre_window_seconds"))
      assert Enum.any?(errors, &(&1 =~ "post_window_seconds"))
      assert Enum.any?(errors, &(&1 =~ "max_event_seconds"))
    end

    test "per-camera window overrides are validated" do
      map =
        update_in(base_map(), ["cameras"], fn [a, b] ->
          [Map.put(a, "post_window_seconds", 0), b]
        end)

      assert {:error, errors} = Config.from_map(map)
      assert Enum.any?(errors, &(&1 =~ "camera cam_a: post_window_seconds"))
    end

    test "tracking.max_unseen_ms must be a sane number of milliseconds" do
      map = Map.put(base_map(), "tracking", %{"max_unseen_ms" => 10})

      assert {:error, errors} = Config.from_map(map)
      assert Enum.any?(errors, &(&1 =~ "tracking.max_unseen_ms must be 100..3600000"))
    end

    test "tracking.max_unseen_ms is rejected above the advertised range too" do
      map = Map.put(base_map(), "tracking", %{"max_unseen_ms" => 3_600_001})

      assert {:error, errors} = Config.from_map(map)
      assert Enum.any?(errors, &(&1 =~ "tracking.max_unseen_ms must be 100..3600000"))
    end

    test "tracking.max_live_tracks must be a sane cap" do
      for value <- [0, 10_001, "lots"] do
        map = Map.put(base_map(), "tracking", %{"max_live_tracks" => value})

        assert {:error, errors} = Config.from_map(map)
        assert Enum.any?(errors, &(&1 =~ "tracking.max_live_tracks must be 1..10000"))
      end
    end

    test "the tracker core resolves camera > profile > global" do
      # The profile fixture names none, so the global answers for its cameras
      # until one of the two more specific levels speaks.
      map = Map.put(base_map(), "tracking", %{"tracker" => "sparsetrack"})
      assert {:ok, config, []} = Config.from_map(map)
      assert Config.tracker(config, hd(config.cameras)) == Cairn.Detect.SparseTrack

      map = update_in(map, ["cameras"], fn [a, b] -> [Map.put(a, "tracker", "cairn"), b] end)
      assert {:ok, config, []} = Config.from_map(map)
      assert Config.tracker(config, hd(config.cameras)) == Cairn.Tracker
      assert Config.tracker(config, List.last(config.cameras)) == Cairn.Detect.SparseTrack
    end

    test "a config that names no tracker gets the cairn core" do
      assert {:ok, config, []} = Config.from_map(base_map())
      assert config.tracker == "cairn"
      assert Config.tracker(config, hd(config.cameras)) == Cairn.Tracker
    end

    test "an unknown tracker name is refused at load, wherever it was named" do
      global = Map.put(base_map(), "tracking", %{"tracker" => "bytetrack"})
      assert {:error, errors} = Config.from_map(global)
      assert Enum.any?(errors, &(&1 =~ ~s(tracking.tracker: unknown tracker "bytetrack")))
      assert Enum.any?(errors, &(&1 =~ "cairn, sparsetrack"))

      per_camera =
        update_in(base_map(), ["cameras"], fn [a, b] -> [Map.put(a, "tracker", "nope"), b] end)

      assert {:error, errors} = Config.from_map(per_camera)
      assert Enum.any?(errors, &(&1 =~ ~s(camera cam_a: tracker: unknown tracker "nope")))
    end

    # `false` is a name no core answers to, and the truthiness a `||` chain
    # resolves it with would read it as "said nothing" and hand the camera the
    # default the operator was refusing.
    test "a tracker of false is refused at load, wherever it was named" do
      global = Map.put(base_map(), "tracking", %{"tracker" => false})
      assert {:error, errors} = Config.from_map(global)
      assert Enum.any?(errors, &(&1 =~ "tracking.tracker: unknown tracker false"))
      assert Enum.any?(errors, &(&1 =~ "cairn, sparsetrack"))

      per_camera =
        update_in(base_map(), ["cameras"], fn [a, b] -> [Map.put(a, "tracker", false), b] end)

      assert {:error, errors} = Config.from_map(per_camera)
      assert Enum.any?(errors, &(&1 =~ "camera cam_a: tracker: unknown tracker false"))
      assert Enum.any?(errors, &(&1 =~ "cairn, sparsetrack"))
    end

    test "per-camera max_live_tracks overrides are validated" do
      map =
        update_in(base_map(), ["cameras"], fn [a, b] ->
          [Map.put(a, "max_live_tracks", 0), b]
        end)

      assert {:error, errors} = Config.from_map(map)
      assert Enum.any?(errors, &(&1 =~ "camera cam_a: max_live_tracks must be 1..10000"))
    end

    test "per-camera max_unseen_ms overrides are validated" do
      map =
        update_in(base_map(), ["cameras"], fn [a, b] ->
          [Map.put(a, "max_unseen_ms", "soon"), b]
        end)

      assert {:error, errors} = Config.from_map(map)
      assert Enum.any?(errors, &(&1 =~ "camera cam_a: max_unseen_ms must be 100..3600000"))
    end

    test "tracking.stationary_after_ms must be a sane number of milliseconds" do
      for value <- [999, 3_600_001, "a while"] do
        map = Map.put(base_map(), "tracking", %{"stationary_after_ms" => value})

        assert {:error, errors} = Config.from_map(map)
        assert Enum.any?(errors, &(&1 =~ "tracking.stationary_after_ms must be 1000..3600000"))
      end
    end

    test "per-camera stationary_after_ms overrides are validated" do
      map =
        update_in(base_map(), ["cameras"], fn [a, b] ->
          [Map.put(a, "stationary_after_ms", 100), b]
        end)

      assert {:error, errors} = Config.from_map(map)
      assert Enum.any?(errors, &(&1 =~ "camera cam_a: stationary_after_ms must be 1000..3600000"))
    end

    test "stationary_after_ms is a known key in both places it may appear" do
      map =
        base_map()
        |> Map.put("tracking", %{"stationary_after_ms" => 20_000})
        |> update_in(["cameras"], fn [a, b] ->
          [Map.put(a, "stationary_after_ms", 5_000), b]
        end)

      assert {:ok, _config, warnings} = Config.from_map(map)
      refute Enum.any?(warnings, &(&1 =~ "stationary_after_ms"))
    end

    test "tracking.bbd is a known key, off unless set, and reaches the policy" do
      {:ok, defaults, []} = Config.from_map(base_map())
      [cam_a, _cam_b] = defaults.cameras
      refute defaults.bbd
      refute Config.default_bbd()
      refute Config.policy(defaults, cam_a).bbd

      {:ok, config, warnings} =
        base_map() |> Map.put("tracking", %{"bbd" => true}) |> Config.from_map()

      [cam_a, cam_b] = config.cameras
      refute Enum.any?(warnings, &(&1 =~ "bbd"))

      # every camera or none: the matcher is one decision for every camera this
      # key answers for, so unlike the three bounds beside it there is no
      # per-camera form of it (the other way to answer it is per plugin group,
      # in a hardware profile, which these two cameras do not have)
      assert Config.policy(config, cam_a).bbd
      assert Config.policy(config, cam_b).bbd

      # an explicit off is off whatever the default says, and a truthy
      # non-boolean is a typo rather than an opt-in — only `true` enables
      for {value, name} <- [{false, "explicit false"}, {"true", "a string"}, {1, "an integer"}] do
        {:ok, config, _warnings} =
          base_map() |> Map.put("tracking", %{"bbd" => value}) |> Config.from_map()

        refute config.bbd, name
      end
    end

    test "tracking.oru is a known key, off unless set, and reaches the policy" do
      {:ok, defaults, []} = Config.from_map(base_map())
      [cam_a, _cam_b] = defaults.cameras
      refute defaults.oru
      refute Config.default_oru()
      refute Config.policy(defaults, cam_a).oru

      {:ok, config, warnings} =
        base_map() |> Map.put("tracking", %{"oru" => true}) |> Config.from_map()

      [cam_a, cam_b] = config.cameras
      refute Enum.any?(warnings, &(&1 =~ "oru"))

      # every camera or none: the motion filter is one decision for the fleet,
      # so unlike the three bounds beside it there is no per-camera form of it
      assert Config.policy(config, cam_a).oru
      assert Config.policy(config, cam_b).oru

      # an explicit off is off whatever the default says, and a truthy
      # non-boolean is a typo rather than an opt-in — only `true` enables
      for {value, name} <- [{false, "explicit false"}, {"true", "a string"}, {1, "an integer"}] do
        {:ok, config, _warnings} =
          base_map() |> Map.put("tracking", %{"oru" => value}) |> Config.from_map()

        refute config.oru, name
      end
    end

    test "tracking.ocr is a known key, off unless set, and reaches the policy" do
      {:ok, defaults, []} = Config.from_map(base_map())
      [cam_a, _cam_b] = defaults.cameras
      refute defaults.ocr
      refute Config.default_ocr()
      refute Config.policy(defaults, cam_a).ocr

      {:ok, config, warnings} =
        base_map() |> Map.put("tracking", %{"ocr" => true}) |> Config.from_map()

      [cam_a, cam_b] = config.cameras
      refute Enum.any?(warnings, &(&1 =~ "ocr"))

      # every camera or none: recovery is one decision for the fleet, so
      # unlike the three bounds beside it there is no per-camera form of it
      assert Config.policy(config, cam_a).ocr
      assert Config.policy(config, cam_b).ocr

      # an explicit off is off whatever the default says, and a truthy
      # non-boolean is a typo rather than an opt-in — only `true` enables
      for {value, name} <- [{false, "explicit false"}, {"true", "a string"}, {1, "an integer"}] do
        {:ok, config, _warnings} =
          base_map() |> Map.put("tracking", %{"ocr" => value}) |> Config.from_map()

        refute config.ocr, name
      end
    end

    test "tracking.reid is a known key, off unless set, and reaches the policy" do
      {:ok, defaults, []} = Config.from_map(base_map())
      [cam_a, _cam_b] = defaults.cameras
      refute defaults.reid
      refute Config.default_reid()
      refute Config.policy(defaults, cam_a).reid

      {:ok, config, warnings} =
        base_map()
        |> Map.put("tracking", %{"reid" => true, "bbd" => true})
        |> Config.from_map()

      [cam_a, cam_b] = config.cameras
      refute Enum.any?(warnings, &(&1 =~ "reid"))

      # every camera or none: reid is one decision for the fleet, so unlike
      # the three bounds beside it there is no per-camera form of it
      assert Config.policy(config, cam_a).reid
      assert Config.policy(config, cam_b).reid

      # an explicit off is off whatever the default says, and a truthy
      # non-boolean is a typo rather than an opt-in — only `true` enables
      for {value, name} <- [{false, "explicit false"}, {"true", "a string"}, {1, "an integer"}] do
        {:ok, config, _warnings} =
          base_map()
          |> Map.put("tracking", %{"reid" => value, "bbd" => true})
          |> Config.from_map()

        refute config.reid, name
      end
    end

    test "tracking.reid requires tracking.bbd where the global flag reaches" do
      # The refusal is scoped to cameras the global booleans govern — those
      # whose group resolves no profile, which since phase 6 is itself a
      # load error (every plugin: camera must resolve a profile), so the
      # reid refusal rides along beside that error rather than replacing it.
      plugged =
        base_map()
        |> Map.put("plugins", %{"det" => %{"profile" => "no-such"}})
        |> update_in(["cameras"], fn [a, b] -> [Map.put(a, "plugin", "det"), b] end)

      assert {:error, errors} =
               plugged
               |> Map.put("tracking", %{"reid" => true})
               |> Config.from_map()

      assert Enum.any?(errors, &(&1 =~ "tracking.reid requires tracking.bbd"))

      assert {:error, errors} =
               plugged
               |> Map.put("tracking", %{"reid" => true, "bbd" => false})
               |> Config.from_map()

      assert Enum.any?(errors, &(&1 =~ "tracking.reid requires tracking.bbd"))

      # With bbd on, the reid refusal itself is gone (the unknown-profile
      # error remains — it is a different defect).
      assert {:error, errors} =
               plugged
               |> Map.put("tracking", %{"reid" => true, "bbd" => true})
               |> Config.from_map()

      refute Enum.any?(errors, &(&1 =~ "tracking.reid requires tracking.bbd"))

      # No plugin-bearing camera reads the global flags, so nothing is
      # refused over them — a config the flag cannot reach is not an error
      # (a fully-profiled deployment answers to its profiles' stage lists,
      # and the per-group warning names any profile that silences reid).
      assert {:ok, config, _warnings} =
               base_map()
               |> Map.put("tracking", %{"reid" => true, "bbd" => true})
               |> Config.from_map()

      assert config.reid
      assert config.bbd
      [cam_a, _cam_b] = config.cameras
      assert Config.policy(config, cam_a).reid
      assert Config.policy(config, cam_a).bbd

      assert {:ok, _config, _warnings} =
               base_map()
               |> Map.put("tracking", %{"reid" => true})
               |> Config.from_map()
    end

    test "retention.tracks_days defaults to a year and parses" do
      assert {:ok, default, []} = Config.from_map(base_map())
      assert default.retention_tracks_days == 365

      map = Map.put(base_map(), "retention", %{"days" => 14, "tracks_days" => 90})
      assert {:ok, config, []} = Config.from_map(map)
      assert config.retention_tracks_days == 90
    end

    test "retention.tracks_days is rejected at both ends of the range" do
      for value <- [0, 10_001, "a year"] do
        map = Map.put(base_map(), "retention", %{"tracks_days" => value})

        assert {:error, errors} = Config.from_map(map)
        assert Enum.any?(errors, &(&1 =~ "retention.tracks_days must be >= 1"))
      end
    end

    test "the global retention.per_label value is bounded like retention.days" do
      for value <- [0, -1, 10_001, "7"] do
        map = Map.put(base_map(), "retention", %{"per_label" => %{"person" => value}})

        assert {:error, errors} = Config.from_map(map)
        assert Enum.any?(errors, &(&1 =~ "retention.per_label.person must be >= 1"))
      end

      map = Map.put(base_map(), "retention", %{"per_label" => %{"person" => 30}})
      assert {:ok, config, []} = Config.from_map(map)
      assert config.retention_per_label == %{"person" => 30}
    end

    test "a false global retention.days or tracks_days is an error, not the default" do
      for key <- ["days", "tracks_days"] do
        map = Map.put(base_map(), "retention", %{key => false})
        assert {:error, errors} = Config.from_map(map)
        assert Enum.any?(errors, &(&1 =~ "retention.#{key} must be >= 1"))
      end
    end

    test "a non-map global retention.per_label is an error, not a crash" do
      for value <- ["30 days", false, 30] do
        map = Map.put(base_map(), "retention", %{"per_label" => value})

        assert {:error, errors} = Config.from_map(map)
        assert "retention.per_label must be a mapping" in errors
      end
    end

    # The camera block goes through `Cairn.Config.Camera`, the parser a form
    # candidate also goes through, so the file and the form agree on it.
    test "a camera's retention.days is bounded like the global one" do
      for value <- [0, -1, 10_001, "7", 1.5] do
        assert {:error, errors} = Config.from_map(camera_retention_map(%{"days" => value}))

        assert Enum.any?(errors, &(&1 =~ "camera cam_a: retention.days must be >= 1"))
      end

      assert {:ok, config, []} = Config.from_map(camera_retention_map(%{"days" => 3}))
      assert [%Config.Camera{retention_days: 3}] = config.cameras
    end

    test "a camera's per-label retention value is bounded the same way" do
      for value <- [0, -1, 10_001, "7", 1.5] do
        map = camera_retention_map(%{"per_label" => %{"person" => value}})

        assert {:error, errors} = Config.from_map(map)

        assert Enum.any?(
                 errors,
                 &(&1 =~ "camera cam_a: retention.per_label (person) must be >= 1")
               )
      end

      map = camera_retention_map(%{"per_label" => %{"person" => 30}})
      assert {:ok, config, []} = Config.from_map(map)
      assert [%Config.Camera{retention_per_label: %{"person" => 30}}] = config.cameras
    end

    test "a camera's retention block that is not a mapping is the camera's error" do
      assert {:error, errors} = Config.from_map(camera_retention_map("30 days"))
      assert "camera cam_a: retention must be a mapping" in errors

      map = camera_retention_map(%{"per_label" => 30})
      assert {:error, errors} = Config.from_map(map)
      assert "camera cam_a: retention.per_label must be a mapping" in errors
    end

    test "an unknown retention key is still only a warning" do
      map = Map.put(base_map(), "retention", %{"track_days" => 90})

      assert {:ok, config, warnings} = Config.from_map(map)
      assert Enum.any?(warnings, &(&1 =~ ~s(unknown key "track_days" in retention)))
      assert config.retention_tracks_days == 365
    end

    test "an unknown tracking key is still only a warning" do
      map = Map.put(base_map(), "tracking", %{"stationary_after_millis" => 20_000})

      assert {:ok, _config, warnings} = Config.from_map(map)
      assert Enum.any?(warnings, &(&1 =~ ~s(unknown key "stationary_after_millis" in tracking)))
    end

    test "duplicate camera ids are an error" do
      map =
        update_in(base_map(), ["cameras"], fn [a, _b] ->
          [a, Map.put(a, "rtsp_url", "rtsp://h/other")]
        end)

      assert {:error, errors} = Config.from_map(map)
      assert Enum.any?(errors, &(&1 =~ "duplicate camera id: cam_a"))
    end

    test "camera without rtsp_url is an error" do
      map = update_in(base_map(), ["cameras"], fn [a, b] -> [Map.delete(a, "rtsp_url"), b] end)
      assert {:error, errors} = Config.from_map(map)
      assert Enum.any?(errors, &(&1 =~ "rtsp_url is required"))
    end

    test "bad camera id is an error" do
      map = update_in(base_map(), ["cameras"], fn [a, b] -> [Map.put(a, "id", "Bad Id!"), b] end)
      assert {:error, errors} = Config.from_map(map)
      assert Enum.any?(errors, &(&1 =~ "id is required"))
    end

    test "a camera id cannot end in a newline" do
      map = update_in(base_map(), ["cameras"], fn [a, b] -> [Map.put(a, "id", "cam_a\n"), b] end)

      assert {:error, errors} = Config.from_map(map)
      assert Enum.any?(errors, &(&1 =~ "camera #0: id is required"))
    end

    test "min_score out of range is an error" do
      map =
        update_in(base_map(), ["cameras"], fn [a, b] ->
          [Map.put(a, "min_score", %{"person" => 1.5}), b]
        end)

      assert {:error, errors} = Config.from_map(map)
      assert Enum.any?(errors, &(&1 =~ "min_score values must be 0..1"))
    end

    test "unknown keys produce warnings, not errors" do
      map =
        base_map()
        |> Map.put("shenanigans", true)
        |> update_in(["cameras"], fn [a, b] -> [Map.put(a, "typo_key", 1), b] end)

      assert {:ok, _config, warnings} = Config.from_map(map)
      assert Enum.any?(warnings, &(&1 =~ ~s(unknown key "shenanigans" in config)))
      assert Enum.any?(warnings, &(&1 =~ ~s(camera cam_a: unknown key "typo_key")))
    end

    test "unknown key on a camera with no valid id warns by index, not by id" do
      raw = %{"id" => "Bad Id!", "rtsp_url" => "rtsp://h/1", "typo_key" => 1}
      assert {nil, acc} = Config.Camera.parse(raw, 0, %{errors: [], warnings: []})
      assert Enum.any?(acc.warnings, &(&1 =~ ~s(unknown key "typo_key" in camera #0)))
    end

    test "an inline plugin command is refused with its remedy, in both spellings" do
      map =
        update_in(base_map(), ["cameras"], fn [a, b] ->
          [Map.put(a, "plugin", "python3 plug.py --x"), Map.put(b, "plugin", ["./plug"])]
        end)

      assert {:error, errors} = Config.from_map(map)

      assert Enum.count(errors, &(&1 =~ "inline plugin commands were removed")) == 2
      assert Enum.any?(errors, &(&1 =~ "camera cam_a"))
      assert Enum.any?(errors, &(&1 =~ "camera cam_b"))
    end
  end

  describe "partition_by_camera/1" do
    test "every error Camera.build emits lands under its camera's id" do
      map =
        update_in(base_map(), ["cameras"], fn [a, b] ->
          faulty =
            Map.merge(a, %{
              "min_score" => %{"person" => 1.5},
              "track" => "nope",
              "ingest" => "carrier-pigeon",
              "substream_url" => "http://x",
              "annotation_offset_ms" => "soon",
              "pipeline" => "classic",
              "extra_ffmpeg_args" => [1],
              "motion_json" => "{not json"
            })

          [faulty, b]
        end)

      assert {:error, errors} = Config.from_map(map)
      {per_camera, fleet} = Config.partition_by_camera(errors)

      assert Map.keys(per_camera) == ["cam_a"]
      assert fleet == []

      msgs = Map.fetch!(per_camera, "cam_a")
      # one message per fault above, and no fault silently folded into another
      assert length(msgs) == 8

      for fragment <- [
            "min_score values must be 0..1",
            "track must be a mapping",
            "ingest must be",
            "substream_url must be an rtsp:// url",
            "annotation_offset_ms must be an integer",
            "classic pipeline was removed",
            "extra_ffmpeg_args must be a list of strings",
            "motion_json:"
          ] do
        assert Enum.any?(msgs, &(&1 =~ fragment)), "no cam_a message matched #{fragment}"
      end
    end

    test "cross-camera and global errors are fleet-level" do
      map =
        base_map()
        |> update_in(["cameras"], fn [a, b] -> [a, Map.put(b, "id", "cam_a")] end)
        |> Map.put("tracking", %{"max_unseen_ms" => -1})

      assert {:error, errors} = Config.from_map(map)
      {per_camera, fleet} = Config.partition_by_camera(errors)

      assert fleet != []
      assert Enum.any?(fleet, &(&1 =~ "duplicate camera id"))
      assert per_camera == %{}
    end

    test "an unknown key on a camera with a valid id warns by id, not by position" do
      map = update_in(base_map(), ["cameras"], fn [a, b] -> [Map.put(a, "typo_key", 1), b] end)

      assert {:ok, _config, warnings} = Config.from_map(map)
      {per_camera, fleet} = Config.partition_by_camera(warnings)

      assert Map.fetch!(per_camera, "cam_a") == [~s(camera cam_a: unknown key "typo_key")]
      assert fleet == []
    end

    test "a camera's messages keep the order from_map returned them" do
      map =
        update_in(base_map(), ["cameras"], fn [a, b] ->
          [Map.merge(a, %{"min_score" => %{"person" => 1.5}, "pipeline" => "classic"}), b]
        end)

      assert {:error, errors} = Config.from_map(map)
      {per_camera, []} = Config.partition_by_camera(errors)

      assert Map.fetch!(per_camera, "cam_a") ==
               Enum.filter(errors, &String.starts_with?(&1, "camera cam_a: "))

      assert length(Map.fetch!(per_camera, "cam_a")) == 2
    end

    test "index-prefixed messages stay fleet-level" do
      messages = [
        "camera #3: id is required ([a-z0-9_-], lowercase)",
        "camera cam_b: rtsp_url is required"
      ]

      assert Config.partition_by_camera(messages) ==
               {%{"cam_b" => ["camera cam_b: rtsp_url is required"]},
                ["camera #3: id is required ([a-z0-9_-], lowercase)"]}
    end
  end

  describe "track/record tiers" do
    # A wire floor below every threshold used here, plus a catch-all record
    # rule above them unless the case supplies its own: a `track:` above the
    # floor with no `record:` block is a monotonicity error, and monotonicity
    # has its own describe block below. These cases are about parsing.
    defp with_tiers(map, tiers) do
      fields =
        %{"min_score" => 0.3}
        |> Map.merge(tiers)
        |> Map.put_new("record", %{"default" => 1.0})

      update_in(map, ["cameras"], fn [a, b] -> [Map.merge(a, fields), b] end)
    end

    defp cam_a(map) do
      assert {:ok, config, warnings} = Config.from_map(map)
      [cam_a, _cam_b] = config.cameras
      {cam_a, config, warnings}
    end

    test "absent blocks parse to nil and change nothing" do
      {cam, config, []} = cam_a(base_map())

      assert cam.track == nil
      assert cam.record == nil
      assert Config.policy(config, cam).track == nil
      assert Config.policy(config, cam).record == nil
    end

    test "a bare number and the map form parse identically" do
      {bare, _config, []} = cam_a(with_tiers(base_map(), %{"track" => %{"person" => 0.4}}))

      {mapped, _config, []} =
        cam_a(with_tiers(base_map(), %{"track" => %{"person" => %{"min_score" => 0.4}}}))

      assert bare.track == %{"person" => %{min_score: 0.4}}
      assert bare.track == mapped.track
    end

    test "both tiers parse, integers are floats, and no default is injected" do
      {cam, _config, []} =
        cam_a(
          with_tiers(base_map(), %{
            "track" => %{"person" => 0.4, "cat" => %{"min_score" => 0.5}},
            "record" => %{"person" => 0.6, "dog" => 1}
          })
        )

      assert cam.track == %{"person" => %{min_score: 0.4}, "cat" => %{min_score: 0.5}}
      assert cam.record == %{"person" => %{min_score: 0.6}, "dog" => %{min_score: 1.0}}
      refute Map.has_key?(cam.track, "default")
      refute Map.has_key?(cam.record, "default")
    end

    test "a default: key is honoured like min_score's" do
      {cam, _config, []} =
        cam_a(with_tiers(base_map(), %{"track" => %{"default" => 0.3, "person" => 0.4}}))

      assert cam.track == %{"default" => %{min_score: 0.3}, "person" => %{min_score: 0.4}}
    end

    test "the tier keys are known keys, so they warn about nothing" do
      {_cam, _config, warnings} =
        cam_a(with_tiers(base_map(), %{"track" => %{"person" => 0.4}, "record" => %{}}))

      assert warnings == []
    end

    test "a non-map block is an error" do
      assert {:error, errors} = Config.from_map(with_tiers(base_map(), %{"track" => 0.4}))
      assert Enum.any?(errors, &(&1 =~ "camera cam_a: track must be a mapping of label"))

      assert {:error, errors} = Config.from_map(with_tiers(base_map(), %{"record" => ["person"]}))
      assert Enum.any?(errors, &(&1 =~ "camera cam_a: record must be a mapping of label"))
    end

    test "bad label values are one error naming every offending label" do
      map =
        with_tiers(base_map(), %{
          "track" => %{"person" => 1.5, "cat" => "yes", "dog" => 0.4, "bird" => %{}}
        })

      assert {:error, errors} = Config.from_map(map)

      assert Enum.any?(
               errors,
               &(&1 =~
                   "camera cam_a: track values must be a number or a map of " <>
                     "{min_score: 0..1} (bird, cat, person)")
             )
    end

    test "an out-of-range score inside the map form is caught like the sugar form" do
      map = with_tiers(base_map(), %{"record" => %{"person" => %{"min_score" => 1.5}}})

      assert {:error, errors} = Config.from_map(map)

      assert Enum.any?(
               errors,
               &(&1 =~
                   "camera cam_a: record values must be a number or a map of " <>
                     "{min_score: 0..1} (person)")
             )
    end

    test "a rule map with a key this version does not implement is an error" do
      map = with_tiers(base_map(), %{"record" => %{"person" => %{"min_area" => 100}}})

      assert {:error, errors} = Config.from_map(map)
      assert Enum.any?(errors, &(&1 =~ "camera cam_a: record values must be"))
    end
  end

  describe "tier monotonicity" do
    defp put_cam_a(map, fields) do
      update_in(map, ["cameras"], fn [a, b] -> [Map.merge(a, fields), b] end)
    end

    test "a track threshold under the wire floor is an error naming camera and label" do
      map =
        put_cam_a(base_map(), %{
          "min_score" => %{"person" => 0.7},
          "track" => %{"person" => 0.4}
        })

      assert {:error, errors} = Config.from_map(map)

      assert Enum.any?(
               errors,
               &(&1 =~ "camera cam_a: track.person (0.4) must be >= min_score.person (0.7)")
             )
    end

    test "a record threshold under its own track threshold is an error" do
      map =
        put_cam_a(base_map(), %{
          "track" => %{"person" => 0.6},
          "record" => %{"person" => 0.5}
        })

      assert {:error, errors} = Config.from_map(map)

      assert Enum.any?(
               errors,
               &(&1 =~ "camera cam_a: record.person (0.5) must be >= track.person (0.6)")
             )
    end

    test "the default chains are compared too, on both sides" do
      map =
        put_cam_a(base_map(), %{
          "min_score" => %{"default" => 0.6},
          "record" => %{"default" => 0.5}
        })

      assert {:error, errors} = Config.from_map(map)

      assert Enum.any?(
               errors,
               &(&1 =~ "camera cam_a: record.default (0.5) must be >= min_score.default (0.6)")
             )

      # a per-label floor against the tier's catch-all: "person" is only in
      # min_score, and record resolves it through its own default.
      map =
        put_cam_a(base_map(), %{
          "min_score" => %{"person" => 0.8},
          "record" => %{"default" => 0.7}
        })

      assert {:error, errors} = Config.from_map(map)

      assert Enum.any?(
               errors,
               &(&1 =~ "camera cam_a: record.person (0.7) must be >= min_score.person (0.8)")
             )
    end

    test "the track pair is compared across the default chains too" do
      map =
        put_cam_a(base_map(), %{
          "min_score" => %{"default" => 0.4, "person" => 0.7},
          "track" => %{"default" => 0.5},
          # a record catch-all above both, so the only rule this case can
          # violate is track-vs-min_score
          "record" => %{"default" => 1.0}
        })

      assert {:error, errors} = Config.from_map(map)

      assert Enum.any?(
               errors,
               &(&1 =~ "camera cam_a: track.person (0.5) must be >= min_score.person (0.7)")
             )
    end

    test "a track above the wire floor with no record: block is an error" do
      map =
        put_cam_a(base_map(), %{
          "min_score" => %{"default" => 0.4},
          "track" => %{"person" => 0.6}
        })

      assert {:error, errors} = Config.from_map(map)

      assert Enum.any?(
               errors,
               &(&1 =~
                   "camera cam_a: track.person (0.6) must be <= the effective record " <>
                     "threshold (0.4) — with no record: block video falls back to min_score, " <>
                     "so a clip could exist with no track row. Give person a record: rule, " <>
                     "or lower track.person")
             )
    end

    test "a present record: block that excludes the label imposes nothing" do
      # tracking without video is the tier working, not a gap: an empty but
      # present record: block means nothing records at all.
      map =
        put_cam_a(base_map(), %{
          "min_score" => %{"default" => 0.4},
          "track" => %{"person" => 0.6},
          "record" => %{}
        })

      assert {:ok, _config, []} = Config.from_map(map)
    end

    test "a record rule at the track threshold closes the gap" do
      map =
        put_cam_a(base_map(), %{
          "min_score" => %{"default" => 0.4},
          "track" => %{"person" => 0.6},
          "record" => %{"person" => 0.6}
        })

      assert {:ok, _config, []} = Config.from_map(map)
    end

    test "equal thresholds pass: the rule is >=, not >" do
      # record == track for "person": the 0.7 band is both logged and filmed.
      assert {:ok, _config, []} =
               base_map()
               |> put_cam_a(%{
                 "min_score" => %{"default" => 0.4},
                 "track" => %{"person" => 0.7},
                 "record" => %{"person" => 0.7}
               })
               |> Config.from_map()

      # track == min_score for "person": the tier admits the whole band the
      # plugin emits for that label, which is the natural way to write it.
      assert {:ok, _config, []} =
               base_map()
               |> put_cam_a(%{
                 "min_score" => %{"default" => 0.4, "person" => 0.5},
                 "track" => %{"person" => 0.5}
               })
               |> Config.from_map()
    end

    test "a label a tier excludes imposes no constraint" do
      map =
        put_cam_a(base_map(), %{
          "min_score" => %{"default" => 0.5, "person" => 0.7},
          # No tier default, so "person" is in neither tier and its 0.7 floor
          # constrains nothing; "cat" is constrained by the 0.5 default floor.
          "track" => %{"cat" => 0.5},
          "record" => %{"cat" => 0.6}
        })

      assert {:ok, _config, []} = Config.from_map(map)
    end

    test "an absent tier reports the violation once, against min_score" do
      map = put_cam_a(base_map(), %{"min_score" => 0.6, "record" => %{"default" => 0.4}})

      assert {:error, errors} = Config.from_map(map)
      assert Enum.filter(errors, &(&1 =~ "record.default")) |> length() == 1
      assert Enum.any?(errors, &(&1 =~ "must be >= min_score.default (0.6)"))
    end

    test "a per-camera tier is validated against that camera's own min_score" do
      map =
        base_map()
        |> put_cam_a(%{
          "min_score" => %{"default" => 0.2},
          "track" => %{"person" => 0.3},
          # cam_a's track sits above its own floor, so it needs a record rule
          # to stay legal; cam_b's sits below its floor and needs none.
          "record" => %{"person" => 0.3}
        })
        |> update_in(["cameras"], fn [a, b] ->
          [a, Map.merge(b, %{"min_score" => %{"default" => 0.9}, "track" => %{"person" => 0.3}})]
        end)

      assert {:error, errors} = Config.from_map(map)
      refute Enum.any?(errors, &(&1 =~ "camera cam_a"))

      assert Enum.any?(
               errors,
               &(&1 =~ "camera cam_b: track.person (0.3) must be >= min_score.person (0.9)")
             )
    end

    test "the ordering that Phases 6 and 7 rely on is accepted end to end" do
      map =
        put_cam_a(base_map(), %{
          "min_score" => %{"default" => 0.4},
          "track" => %{"person" => 0.4, "cat" => 0.5},
          "record" => %{"person" => 0.6}
        })

      assert {:ok, _config, []} = Config.from_map(map)
    end
  end

  describe "tier_threshold/3" do
    @min_score %{"default" => 0.5, "person" => 0.7}

    test "an absent tier falls back to the wire floor for the label" do
      assert Config.tier_threshold(nil, "person", @min_score) == 0.7
      assert Config.tier_threshold(nil, "cat", @min_score) == 0.5
    end

    test "a present tier excludes labels it does not list" do
      rules = %{"person" => %{min_score: 0.8}}

      assert Config.tier_threshold(rules, "person", @min_score) == 0.8
      assert Config.tier_threshold(rules, "cat", @min_score) == :excluded
    end

    test "an empty tier excludes everything" do
      assert Config.tier_threshold(%{}, "person", @min_score) == :excluded
    end

    test "the tier's own default catches unlisted labels" do
      rules = %{"default" => %{min_score: 0.6}}

      assert Config.tier_threshold(rules, "cat", @min_score) == 0.6
    end

    test "an explicit label wins over the tier default" do
      rules = %{"default" => %{min_score: 0.6}, "person" => %{min_score: 0.9}}

      assert Config.tier_threshold(rules, "person", @min_score) == 0.9
      assert Config.tier_threshold(rules, "cat", @min_score) == 0.6
    end
  end

  describe "plugin groups" do
    @argv_profiles "test/support/fixtures/profiles/argv"

    defp with_plugins(map, plugins) do
      map
      |> Map.put("plugins", plugins)
      |> Map.put_new("profile_dirs", [@argv_profiles])
    end

    defp put_plugin(map, index, plugin) do
      update_in(map, ["cameras"], fn cams ->
        List.update_at(cams, index, &Map.put(&1, "plugin", plugin))
      end)
    end

    test "loads the plugin group fixture" do
      assert {:ok, config, []} = Config.load(@groups_fixture)

      assert [detect, spare] = config.plugin_groups
      assert detect.name == "detect"
      assert %Config.Profile{name: "partial"} = detect.profile
      assert %Config.Profile{name: "partial"} = spare.profile

      assert [
               %{id: "cam_a", plugin: {:group, "detect"}},
               %{id: "cam_b", plugin: nil},
               %{id: "cam_c", plugin: {:group, "detect"}}
             ] = config.cameras
    end

    test "a single-token plugin string references a named group" do
      map =
        base_map()
        |> with_plugins(%{"detect" => %{"profile" => "partial"}})
        |> put_plugin(0, "detect")

      assert {:ok, config, []} = Config.from_map(map)
      assert [%{plugin: {:group, "detect"}}, %{plugin: nil}] = config.cameras
      assert [%{name: "detect", profile: %Config.Profile{name: "partial"}}] = config.plugin_groups
    end

    test "a single-token plugin string with no matching group is an error" do
      map = put_plugin(base_map(), 0, "detekt")

      assert {:error, errors} = Config.from_map(map)
      assert Enum.any?(errors, &(&1 =~ ~s(camera cam_a: unknown plugin "detekt")))
    end

    test "ingest defaults to the ffmpeg bridge and accepts rtsp only where it can work" do
      # Default: absent key is the bridge.
      assert {:ok, config, []} = Config.from_map(base_map())
      assert [%{ingest: :ffmpeg}, %{ingest: :ffmpeg}] = config.cameras

      # Valid: an rtsp:// url.
      map =
        update_in(base_map(), ["cameras"], fn [a, b] ->
          [Map.put(a, "ingest", "rtsp"), b]
        end)

      assert {:ok, config, []} = Config.from_map(map)
      assert [%{ingest: :rtsp}, %{ingest: :ffmpeg}] = config.cameras
    end

    test "substream_url is optional, rtsp:// only, and rides any ingest" do
      assert {:ok, config, []} = Config.from_map(base_map())
      assert [%{substream_url: nil}, %{substream_url: nil}] = config.cameras

      # The sub stream is read by the RTSP source element whatever the main
      # stream's ingest is — with the bridge, that element runs sub-only.
      with_sub = fn attrs ->
        update_in(base_map(), ["cameras"], fn [a, b] -> [Map.merge(a, attrs), b] end)
      end

      assert {:ok, config, []} =
               Config.from_map(with_sub.(%{"substream_url" => "rtsp://h/1_sub"}))

      assert [%{substream_url: "rtsp://h/1_sub", ingest: :ffmpeg}, _b] = config.cameras

      assert {:ok, config, []} =
               Config.from_map(
                 with_sub.(%{"substream_url" => "rtsp://h/1_sub", "ingest" => "rtsp"})
               )

      assert [%{substream_url: "rtsp://h/1_sub", ingest: :rtsp}, _b] = config.cameras

      for bad <- ["http://h/1_sub", "", 5] do
        assert {:error, errors} = Config.from_map(with_sub.(%{"substream_url" => bad}))

        assert Enum.any?(errors, &(&1 =~ "camera cam_a: substream_url must be an rtsp:// url")),
               inspect(errors)
      end
    end

    test "rtsp ingest is refused at load where its preconditions fail" do
      refused = fn camera_attrs, message ->
        map =
          update_in(base_map(), ["cameras"], fn [a, b] -> [Map.merge(a, camera_attrs), b] end)

        assert {:error, errors} = Config.from_map(map)
        assert Enum.any?(errors, &(&1 =~ message)), inspect(errors)
      end

      # The rtsp library rejects non-rtsp:// schemes outright (the FLV
      # camera keeps the bridge — D-M7's per-camera escape hatch).
      refused.(
        %{"ingest" => "rtsp", "rtsp_url" => "http://h/flv"},
        "requires an rtsp:// url"
      )

      # Transcode happens inside ffmpeg, which this ingest removes.
      refused.(%{"ingest" => "rtsp", "transcode" => true}, "cannot transcode")

      # A typo is an error, never a silent fallback.
      refused.(%{"ingest" => "rtps"}, "ingest must be")
    end

    test "pipeline: membrane is tolerated; pipeline: classic is refused by name" do
      tolerated =
        update_in(base_map(), ["cameras"], fn [a, b] ->
          [Map.put(a, "pipeline", "membrane"), b]
        end)

      assert {:ok, _config, []} = Config.from_map(tolerated)

      refused =
        update_in(base_map(), ["cameras"], fn [a, b] ->
          [Map.put(a, "pipeline", "classic"), b]
        end)

      assert {:error, errors} = Config.from_map(refused)
      assert Enum.any?(errors, &(&1 =~ "camera cam_a: the classic pipeline was removed"))

      typo =
        update_in(base_map(), ["cameras"], fn [a, b] ->
          [Map.put(a, "pipeline", "membrane2"), b]
        end)

      assert {:error, errors} = Config.from_map(typo)
      assert Enum.any?(errors, &(&1 =~ ~s(pipeline is "membrane" or absent)))
    end

    test "a group nobody references still parses" do
      map = with_plugins(base_map(), %{"detect" => %{"profile" => "partial"}})

      assert {:ok, config, []} = Config.from_map(map)
      assert [%{name: "detect"}] = config.plugin_groups
    end

    test "profile is required and must be a profile name string" do
      assert {:error, errors} = Config.from_map(with_plugins(base_map(), %{"detect" => %{}}))
      assert Enum.any?(errors, &(&1 =~ "plugin detect: profile is required"))

      assert {:error, errors} =
               Config.from_map(with_plugins(base_map(), %{"detect" => %{"profile" => 42}}))

      assert Enum.any?(errors, &(&1 =~ "plugin detect: profile must be a profile name string"))
    end

    test "a leftover command: key from before phase 6 is a warning, not an error" do
      map =
        with_plugins(base_map(), %{
          "detect" => %{"profile" => "partial", "command" => "./cairn-detect"}
        })

      assert {:ok, _config, warnings} = Config.from_map(map)
      assert Enum.any?(warnings, &(&1 =~ ~s(unknown key "command" in plugin detect)))
    end

    test "a camera referencing a group that failed to parse gets no extra error" do
      map =
        base_map()
        |> with_plugins(%{"detect" => %{"profile" => 42}})
        |> put_plugin(0, "detect")

      assert {:error, errors} = Config.from_map(map)
      assert Enum.any?(errors, &(&1 =~ "plugin detect: profile must be"))
      refute Enum.any?(errors, &(&1 =~ "unknown plugin"))
    end

    test "an invalid group name is an error" do
      map = with_plugins(base_map(), %{"Detect Group" => %{"profile" => "partial"}})

      assert {:error, errors} = Config.from_map(map)
      assert Enum.any?(errors, &(&1 =~ "plugin Detect Group: name must be lowercase"))
    end

    test "a group name colliding with a camera id is an error" do
      map = with_plugins(base_map(), %{"cam_a" => %{"profile" => "partial"}})

      assert {:error, errors} = Config.from_map(map)
      assert Enum.any?(errors, &(&1 =~ "plugin cam_a: name collides with a camera id"))
    end

    test "a non-map plugins value is an error" do
      assert {:error, errors} = Config.from_map(with_plugins(base_map(), ["detect"]))
      assert Enum.any?(errors, &(&1 =~ "plugins must be a mapping"))
    end

    test "unknown keys inside a plugin produce warnings" do
      map =
        with_plugins(base_map(), %{
          "detect" => %{"profile" => "partial", "typo_key" => true}
        })

      assert {:ok, _config, warnings} = Config.from_map(map)
      assert Enum.any?(warnings, &(&1 =~ ~s(unknown key "typo_key" in plugin detect)))
    end
  end

  describe "profiles" do
    alias Cairn.Config.Profile

    @profiles_dir "test/support/fixtures/profiles/valid"
    @shadow_dir "test/support/fixtures/profiles/shadow"
    @bad_dir "test/support/fixtures/profiles/bad"

    # `rk-test` is an experimental rknn profile, so the group acknowledges the
    # stubbed backend; an ort profile ignores the key.
    defp profiled_map(profile \\ "rk-test") do
      base_map()
      |> Map.put("profile_dirs", [@profiles_dir])
      |> Map.put("plugins", %{
        "det" => %{"profile" => profile, "allow_experimental" => true}
      })
      |> put_plugin(0, "det")
    end

    test "a profile's tracker outranks the global and yields to the camera's" do
      map = Map.put(profiled_map(), "tracking", %{"tracker" => "cairn"})
      assert {:ok, config, _warnings} = Config.from_map(map)

      # cam_a is on the profiled group, cam_b on none
      assert [profiled, unprofiled] = config.cameras
      assert Config.tracker(config, profiled) == Cairn.Detect.SparseTrack
      assert Config.tracker(config, unprofiled) == Cairn.Tracker

      map = update_in(map, ["cameras"], fn [a, b] -> [Map.put(a, "tracker", "cairn"), b] end)
      assert {:ok, config, _warnings} = Config.from_map(map)
      assert Config.tracker(config, hd(config.cameras)) == Cairn.Tracker
    end

    test "a profile's tracker of false is refused at load like any other non-name" do
      dir =
        tmp_profile_dir("falsy", """
        backend: ort
        model:
          onnx: test/support/fixtures/models/stub.onnx
        tracking:
          tracker: false
        """)

      map =
        base_map()
        |> Map.put("profile_dirs", [dir])
        |> Map.put("plugins", %{"det" => %{"profile" => "falsy"}})
        |> put_plugin(0, "det")

      assert {:error, errors} = Config.from_map(map)
      assert Enum.any?(errors, &(&1 =~ "profile falsy: tracking.tracker: unknown tracker false"))
      assert Enum.any?(errors, &(&1 =~ "cairn, sparsetrack"))
    end

    test "a profiled group resolves its file into the parsed struct" do
      assert {:ok, config, []} = Config.from_map(profiled_map())

      assert [%{profile: %Profile{} = profile}] = config.plugin_groups
      assert profile.name == "rk-test"
      assert profile.backend == "rknn"
      assert profile.experimental
      assert profile.fps_band == [2, 4]
      assert profile.max_unseen_ms == 6000
      # Presence map: params keep their YAML string keys, `true` reads as
      # empty params.
      assert profile.stages == %{bbd: %{}, oru: %{"step_ms" => 700}, twin_mint: %{}}
    end

    test "an unknown profile name is a config error naming the search" do
      assert {:error, errors} = Config.from_map(profiled_map("no-such"))
      assert Enum.any?(errors, &(&1 =~ "unknown profile \"no-such\""))
    end

    test "a later dir shadows an earlier one, with a warning" do
      map = Map.update!(profiled_map(), "profile_dirs", &(&1 ++ [@shadow_dir]))

      assert {:ok, config, warnings} = Config.from_map(map)
      assert Enum.any?(warnings, &(&1 =~ "shadows a previously loaded profile"))

      # The shadow file wins: ort backend, twin_mint only.
      assert [%{profile: %Profile{backend: "ort", stages: %{twin_mint: %{}} = stages}}] =
               config.plugin_groups

      refute Map.has_key?(stages, :bbd)
    end

    test "a broken profile file fails the whole load with named errors" do
      map = Map.put(base_map(), "profile_dirs", [@bad_dir])

      assert {:error, errors} = Config.from_map(map)
      assert Enum.any?(errors, &(&1 =~ "unknown backend \"quantum\""))
      assert Enum.any?(errors, &(&1 =~ "fps_band must be"))
      assert Enum.any?(errors, &(&1 =~ "tracking.bbd must be"))
    end

    test "a name key that contradicts the filename is an error" do
      map = Map.put(base_map(), "profile_dirs", ["test/support/fixtures/profiles/mismatch"])

      assert {:error, errors} = Config.from_map(map)
      assert Enum.any?(errors, &(&1 =~ "does not match its filename"))
    end

    @bad_types_dir "test/support/fixtures/profiles/bad-types"

    test "model: as a scalar fails with 'model must be a mapping'" do
      map = Map.put(base_map(), "profile_dirs", [@bad_types_dir])

      assert {:error, errors} = Config.from_map(map)

      assert Enum.any?(
               errors,
               &(&1 =~
                   "profile model-string: model must be a mapping of per-backend " <>
                     "artifact paths")
             )
    end

    test "a non-string model leaf fails with 'model.<key> must be a path string'" do
      map = Map.put(base_map(), "profile_dirs", [@bad_types_dir])

      assert {:error, errors} = Config.from_map(map)
      assert Enum.any?(errors, &(&1 =~ "profile model-leaf: model.onnx must be a path string"))
    end

    test "a non-string labels: fails with 'labels must be a string'" do
      map = Map.put(base_map(), "profile_dirs", [@bad_types_dir])

      assert {:error, errors} = Config.from_map(map)
      assert Enum.any?(errors, &(&1 =~ "profile labels-type: labels must be a string"))
    end

    test "experimental: as a non-boolean fails with 'must be true or false'" do
      map = Map.put(base_map(), "profile_dirs", [@bad_types_dir])

      assert {:error, errors} = Config.from_map(map)

      assert Enum.any?(
               errors,
               &(&1 =~ "profile experimental-type: experimental must be true or false")
             )
    end

    test "a profile with no tracking block leaves the boolean path standing" do
      # `minimal.yml` has no `tracking:` block (just the backend and its
      # artifact), so the policy carries no stages key and the camera reads
      # the global flags — the absence-speaks rule's other half.
      assert {:ok, config, []} = Config.from_map(profiled_map("minimal"))
      [profiled | _rest] = config.cameras

      policy = Config.policy(config, profiled)
      refute Map.has_key?(policy, :stages)
      assert policy.max_unseen_ms == 3_000
    end

    test "presence purity reaches the policy: only the listed stage is in it" do
      map = Map.update!(profiled_map(), "profile_dirs", &(&1 ++ [@shadow_dir]))

      assert {:ok, config, _warnings} = Config.from_map(map)
      [profiled | _rest] = config.cameras

      # The shadow profile lists twin_mint alone: bbd and oru are absent from
      # the policy's map — delisted, not defaulted — which is what the
      # tracker's stages path reads.
      assert Config.policy(config, profiled).stages == %{twin_mint: %{}}
    end

    test "an out-of-range profile bound fails the load on the shared ranges" do
      map = Map.put(base_map(), "profile_dirs", ["test/support/fixtures/profiles/lowbound"])

      assert {:error, errors} = Config.from_map(map)
      assert Enum.any?(errors, &(&1 =~ "tracking.max_unseen_ms must be an integer between"))
    end

    test "policy/2 gives profiled cameras the stage map and band-tuned bounds" do
      assert {:ok, config, []} = Config.from_map(profiled_map())
      [profiled, unprofiled] = config.cameras

      policy = Config.policy(config, profiled)
      # The profile's stages ride the policy; the booleans stay for the
      # unprofiled path and are superseded on this one.
      assert policy.stages == %{bbd: %{}, oru: %{"step_ms" => 700}, twin_mint: %{}}
      # Profile bound beats the global default; nothing camera-side set.
      assert policy.max_unseen_ms == 6000

      plain = Config.policy(config, unprofiled)
      refute Map.has_key?(plain, :stages)
      assert plain.max_unseen_ms == 3_000
    end

    test "a camera's own bound outranks its profile's" do
      map =
        update_in(profiled_map(), ["cameras"], fn [cam | rest] ->
          [Map.put(cam, "max_unseen_ms", 9_000) | rest]
        end)

      assert {:ok, config, []} = Config.from_map(map)
      [profiled | _rest] = config.cameras
      assert Config.policy(config, profiled).max_unseen_ms == 9_000
    end

    test "global booleans under a profiled group warn that the profile wins" do
      map = Map.put(profiled_map(), "tracking", %{"bbd" => true})

      assert {:ok, _config, warnings} = Config.from_map(map)

      assert Enum.any?(
               warnings,
               &(&1 =~ "profile rk-test supersedes the global tracking.bbd/oru")
             )
    end
  end

  describe "capability tier (profile tier:)" do
    # The ascending-ladder `tier:` on profiles. The `track:`/`record:` score
    # thresholds covered elsewhere in this file share the word "tier" and
    # nothing else.
    defp tiered_map(yaml) do
      dir = tmp_profile_dir("tiered", yaml)

      base_map()
      |> Map.put("profile_dirs", [dir])
      |> Map.put("plugins", %{"det" => %{"profile" => "tiered"}})
      |> put_plugin(0, "det")
    end

    defp ort_yaml(extra) do
      """
      backend: ort
      model:
        onnx: test/support/fixtures/models/stub.onnx
      #{extra}
      """
    end

    test "a declared tier parses and reaches the profiled camera's policy" do
      assert {:ok, config, []} = Config.from_map(tiered_map(ort_yaml("tier: 2")))

      assert [%{profile: %Cairn.Config.Profile{tier: 2}}] = config.plugin_groups

      # cam_a is on the profiled group; cam_b is on no group and must not
      # grow the key from someone else's profile.
      assert [profiled, unprofiled] = config.cameras
      assert Config.policy(config, profiled)[:tier] == 2
      refute Map.has_key?(Config.policy(config, unprofiled), :tier)
    end

    test "tier 1 without a tracking block is legal and reaches the policy" do
      assert {:ok, config, []} = Config.from_map(tiered_map(ort_yaml("tier: 1")))
      assert Config.policy(config, hd(config.cameras))[:tier] == 1
    end

    test "a rung outside the shipped ladder is refused naming the menu" do
      assert {:error, errors} = Config.from_map(tiered_map(ort_yaml("tier: 3")))
      assert Enum.any?(errors, &(&1 =~ "profile tiered: unknown tier 3"))
      assert Enum.any?(errors, &(&1 =~ "1 or 2"))
      assert Enum.any?(errors, &(&1 =~ "higher rungs are reserved"))
    end

    test "a non-integer tier is refused by the same rule" do
      assert {:error, errors} = Config.from_map(tiered_map(ort_yaml(~s(tier: "1"))))
      assert Enum.any?(errors, &(&1 =~ ~s(profile tiered: unknown tier "1")))
    end

    test "tier 1 with a tracking block is a contradiction, failed loud" do
      yaml = ort_yaml("tier: 1\ntracking:\n  twin_mint: true")
      assert {:error, errors} = Config.from_map(tiered_map(yaml))

      assert Enum.any?(
               errors,
               &(&1 =~ "profile tiered: tier 1 is presence detection and runs no tracker")
             )
    end

    test "tier 1 with an empty tracking block is refused the same way" do
      # Present-but-empty is still the stage list saying "run nothing"
      # (`Profile.stages/1`) — machinery the tier turns off either way.
      assert {:error, errors} = Config.from_map(tiered_map(ort_yaml("tier: 1\ntracking: {}")))
      assert Enum.any?(errors, &(&1 =~ "tier 1 is presence detection"))
    end

    test "tier 1 with a bare tracking: key is legal — nil means absent" do
      # The value, not the key: a dangling `tracking:` parses to nil, which
      # the whole module reads as "said nothing about tracking" — the
      # contradiction needs an actual stage list.
      assert {:ok, config, []} = Config.from_map(tiered_map(ort_yaml("tier: 1\ntracking:")))
      assert Config.policy(config, hd(config.cameras))[:tier] == 1
    end

    test "tier 2 with a tracking block is the ordinary legal shape" do
      yaml = ort_yaml("tier: 2\ntracking:\n  twin_mint: true")
      assert {:ok, config, []} = Config.from_map(tiered_map(yaml))

      assert [%{profile: %Cairn.Config.Profile{tier: 2, stages: %{twin_mint: %{}}}}] =
               config.plugin_groups
    end

    test "a float rung is refused like any other non-member" do
      assert {:error, errors} = Config.from_map(tiered_map(ort_yaml("tier: 1.0")))
      assert Enum.any?(errors, &(&1 =~ "profile tiered: unknown tier 1.0"))
    end

    test "an absent tier leaves every policy map without the key" do
      # The D-S5 bit-identity spelling at the policy level: a tier-less
      # profile's policy — and an unprofiled camera's — must be
      # indistinguishable from before the key existed. The golden replay
      # suite holds the behavioral half.
      assert {:ok, config, []} = Config.from_map(profiled_map())

      for cam <- config.cameras do
        refute Map.has_key?(Config.policy(config, cam), :tier)
      end
    end
  end

  describe "track: inert at tier 1" do
    defp tiered_track_map(profile_yaml, cam_fields) do
      update_in(tiered_map(profile_yaml), ["cameras", Access.at(0)], &Map.merge(&1, cam_fields))
    end

    test "an invalid track: shape at tier 1 still errors — the warning doesn't mask it" do
      map = tiered_track_map(ort_yaml("tier: 1"), %{"track" => 0.4})

      assert {:error, errors} = Config.from_map(map)
      assert Enum.any?(errors, &(&1 =~ "camera cam_a: track must be a mapping of label"))
    end

    test "a tier-2 camera's track: draws no warning at all" do
      map =
        tiered_track_map(ort_yaml("tier: 2"), %{
          "min_score" => 0.3,
          "track" => %{"person" => 0.4},
          "record" => %{"default" => 1.0}
        })

      assert {:ok, _config, []} = Config.from_map(map)
    end

    test "a tier-1 camera's track: warns; record: alone does not" do
      map =
        tiered_track_map(ort_yaml("tier: 1"), %{
          "min_score" => 0.3,
          "track" => %{"person" => 0.4},
          "record" => %{"default" => 1.0}
        })

      assert {:ok, _config, warnings} = Config.from_map(map)

      assert Enum.any?(
               warnings,
               &(&1 =~ "camera cam_a: track: has no effect at tier 1" and
                   &1 =~ "record: gates presence recordings")
             )

      record_only = tiered_track_map(ort_yaml("tier: 1"), %{"record" => %{"default" => 1.0}})

      assert {:ok, _config, warnings} = Config.from_map(record_only)
      refute Enum.any?(warnings, &(&1 =~ "has no effect at tier 1"))
    end

    test "two tier-1 cameras with track: warn once each" do
      fields = %{
        "min_score" => 0.3,
        "track" => %{"person" => 0.4},
        "record" => %{"default" => 1.0}
      }

      map =
        tiered_track_map(ort_yaml("tier: 1"), fields)
        |> put_plugin(1, "det")
        |> update_in(["cameras", Access.at(1)], &Map.merge(&1, fields))

      assert {:ok, _config, warnings} = Config.from_map(map)

      inert = Enum.filter(warnings, &(&1 =~ "has no effect at tier 1"))
      assert Enum.count(inert, &(&1 =~ "camera cam_a:")) == 1
      assert Enum.count(inert, &(&1 =~ "camera cam_b:")) == 1
      assert length(inert) == 2
    end
  end

  describe "zones" do
    @zone %{"id" => "drive", "name" => "Driveway", "points" => [[0, 0], [1, 0], [1, 1]]}

    # cam_a is on no plugin group here, so these also carry the inert case.
    defp zoned_map(zones) do
      update_in(base_map(), ["cameras", Access.at(0)], &Map.put(&1, "zones", zones))
    end

    defp zoned_tier_map(profile_yaml) do
      update_in(
        tiered_map(profile_yaml),
        ["cameras", Access.at(0)],
        &Map.put(&1, "zones", [@zone])
      )
    end

    test "zones reach the camera atom-keyed, with float points" do
      assert {:ok, config, _warnings} = Config.from_map(zoned_map([@zone]))

      assert [%Config.Camera{id: "cam_a", zones: zones}, %Config.Camera{zones: []}] =
               config.cameras

      assert zones == [
               %{id: "drive", name: "Driveway", points: [[0.0, 0.0], [1.0, 0.0], [1.0, 1.0]]}
             ]
    end

    test "a broken zone is a load error naming the camera and the zone" do
      assert {:error, errors} =
               Config.from_map(zoned_map([Map.put(@zone, "points", [[0, 0], [1, 0]])]))

      assert "camera cam_a: zone drive: a zone needs at least 3 points" in errors
      assert "camera cam_a: zone drive: the zone has no area" in errors
    end

    test "a zone with no usable id is named by its position" do
      assert {:error, errors} = Config.from_map(zoned_map([Map.put(@zone, "id", "Bad Id")]))
      assert "camera cam_a: zone #0: use lowercase letters, digits, - and _" in errors
    end

    test "two zones on one camera cannot share an id" do
      assert {:error, errors} =
               Config.from_map(zoned_map([@zone, Map.put(@zone, "name", "Second")]))

      assert "camera cam_a: zone drive: already used on this camera" in errors
    end

    test "a duplicate id is reported even when its twin failed on another rule" do
      broken_twin = Map.put(@zone, "name", "")

      assert {:error, errors} =
               Config.from_map(zoned_map([broken_twin, Map.put(@zone, "name", "Second")]))

      assert "camera cam_a: zone drive: give the zone a name" in errors
      assert "camera cam_a: zone drive: already used on this camera" in errors
    end

    test "zones that are not a list are refused" do
      assert {:error, errors} = Config.from_map(zoned_map(%{"drive" => @zone}))
      assert "camera cam_a: zones must be a list" in errors
    end

    # The third state of the load-warning rule: invalid errors above, effective
    # here, and inert warns below.
    test "zones on a tier-1 camera pass silently — that is where they filter" do
      assert {:ok, config, []} = Config.from_map(zoned_tier_map(ort_yaml("tier: 1")))
      assert [%Config.Camera{zones: [%{id: "drive"}]}, _cam_b] = config.cameras
    end

    test "zones on a camera that runs no presence detection warn" do
      assert {:ok, _config, warnings} = Config.from_map(zoned_map([@zone]))

      assert Enum.any?(
               warnings,
               &(&1 =~ "camera cam_a: zones have no effect" and
                   &1 =~ "zones filter tier-1 presence")
             )
    end

    test "a tier-2 or tier-less profile is inert for zones the same way" do
      for yaml <- [ort_yaml("tier: 2"), ort_yaml("")] do
        assert {:ok, _config, warnings} = Config.from_map(zoned_tier_map(yaml))
        assert Enum.any?(warnings, &(&1 =~ "camera cam_a: zones have no effect"))
      end
    end

    test "a camera with no zones is never warned about" do
      assert {:ok, config, []} = Config.from_map(base_map())
      assert Enum.all?(config.cameras, &(&1.zones == []))
    end
  end

  describe "motion gate ownership (D-S4)" do
    # `enabled` said outright: without it the string resolves to no
    # detector and the load warns (its own test below).
    @motion ~s({"enabled": true, "threshold": 30})

    # `tiered_map/1`'s shape with the operator's knob on the profiled camera.
    defp gated_map(profile_yaml, motion \\ @motion) do
      profile_yaml
      |> tiered_map()
      |> update_in(["cameras"], fn [a, b] -> [Map.put(a, "motion_json", motion), b] end)
    end

    test "a tier-2 group refuses the camera's motion_json, naming both sides" do
      assert {:error, errors} = Config.from_map(gated_map(ort_yaml("tier: 2")))

      assert Enum.any?(
               errors,
               &(&1 =~ "camera cam_a: motion_json contradicts its group's tier: 2 profile")
             )

      assert Enum.any?(errors, &(&1 =~ "claim tier: 1"))
    end

    test "tier 1 gates freely — that tier runs gated by design" do
      assert {:ok, config, []} = Config.from_map(gated_map(ort_yaml("tier: 1")))
      assert hd(config.cameras).motion_json == @motion
    end

    test "a tier-less profile keeps today's behavior: the knob passes through" do
      assert {:ok, config, []} = Config.from_map(gated_map(ort_yaml("")))
      assert hd(config.cameras).motion_json == @motion
    end

    test "an unprofiled camera's motion_json is not config's business" do
      map =
        update_in(base_map(), ["cameras"], fn [a, b] ->
          [a, Map.put(b, "motion_json", @motion)]
        end)

      assert {:ok, config, []} = Config.from_map(map)
      assert Enum.at(config.cameras, 1).motion_json == @motion
    end

    test "a tier-2 group without the knob passes cleanly — the refusal needs both sides" do
      assert {:ok, _config, []} = Config.from_map(tiered_map(ort_yaml("tier: 2")))
    end

    test "malformed motion_json is a load error naming the camera, not a build crash" do
      assert {:error, errors} = Config.from_map(gated_map(ort_yaml("tier: 1"), "not json"))
      assert Enum.any?(errors, &(&1 =~ "camera cam_a: motion_json:"))
    end

    test "valid JSON with an unknown knob is the same load error the build would raise" do
      # The exact string `Cairn.Pipeline.Camera.motion_gate/3` raises on —
      # load validation exists so that raise is unreachable from config.
      assert {:error, errors} =
               Config.from_map(gated_map(ort_yaml("tier: 1"), ~s({"treshold":30})))

      assert Enum.any?(errors, &(&1 =~ "camera cam_a: motion_json: unknown motion knob"))
    end

    test "a string resolving to no detector is carried but warned about" do
      # Legal vocabulary, nothing enabled: the gate is never built, which an
      # operator who wrote a scene config surely did not mean — the
      # silent-fallback lesson, at config load instead of on the NPU.
      assert {:ok, config, warnings} =
               Config.from_map(gated_map(ort_yaml("tier: 1"), ~s({"threshold": 30})))

      assert hd(config.cameras).motion_json == ~s({"threshold": 30})
      assert Enum.any?(warnings, &(&1 =~ "camera cam_a: motion_json resolves to no detector"))
    end

    test "a non-string motion_json is refused" do
      assert {:error, errors} = Config.from_map(gated_map(ort_yaml("tier: 1"), 42))
      assert Enum.any?(errors, &(&1 =~ "camera cam_a: motion_json must be a JSON string"))
    end
  end

  describe "annotation_offset_ms" do
    defp offset_map(value) do
      base_map()
      |> Map.put("cameras", [
        Map.merge(%{"id" => "cam_a", "rtsp_url" => "rtsp://h/1"}, value)
      ])
    end

    # The three states the standing rule asks for: absent is identity, a set
    # value is carried, and an unusable one is an error naming itself.
    test "absent is zero, and zero is what every consumer treats as identity" do
      assert {:ok, config, _warnings} = Config.from_map(offset_map(%{}))
      assert [%Config.Camera{annotation_offset_ms: 0}] = config.cameras
      assert Config.annotation_offset_ms(config, "cam_a") == 0
    end

    test "a signed value is carried through, both ways" do
      assert {:ok, late, _} = Config.from_map(offset_map(%{"annotation_offset_ms" => 750}))
      assert Config.annotation_offset_ms(late, "cam_a") == 750

      assert {:ok, early, _} = Config.from_map(offset_map(%{"annotation_offset_ms" => -750}))
      assert Config.annotation_offset_ms(early, "cam_a") == -750
    end

    test "a value past the bound is refused, naming the bound and the value" do
      assert {:error, errors} = Config.from_map(offset_map(%{"annotation_offset_ms" => 45_000}))

      assert Enum.any?(
               errors,
               &(&1 =~ "camera cam_a: annotation_offset_ms must be within ±30000 ms (got 45000)")
             )

      # The bound itself is inclusive, both signs; one past it is not.
      for ok <- [30_000, -30_000] do
        assert {:ok, _config, _warnings} =
                 Config.from_map(offset_map(%{"annotation_offset_ms" => ok}))
      end

      assert {:error, _errors} =
               Config.from_map(offset_map(%{"annotation_offset_ms" => -30_001}))
    end

    test "a non-integer is refused rather than rounded" do
      for bad <- [1.5, "250", %{"ms" => 1}, true] do
        assert {:error, errors} = Config.from_map(offset_map(%{"annotation_offset_ms" => bad}))

        assert Enum.any?(
                 errors,
                 &(&1 =~ "camera cam_a: annotation_offset_ms must be an integer number of ms")
               ),
               "expected an error for #{inspect(bad)}"
      end
    end

    # The event and its clip outlive the camera that made them.
    test "a camera the config no longer has reads as zero, not a crash" do
      assert {:ok, config, _} = Config.from_map(offset_map(%{"annotation_offset_ms" => 500}))
      assert Config.annotation_offset_ms(config, "cam_gone") == 0
    end
  end

  describe "group profile checks" do
    @argv_dir "test/support/fixtures/profiles/argv"
    @no_artifact_dir "test/support/fixtures/profiles/no-artifact"
    @stub_onnx "test/support/fixtures/models/stub.onnx"

    defp argv_map(profile, group \\ %{}, dir \\ @argv_dir) do
      base_map()
      |> Map.put("profile_dirs", [dir])
      |> Map.put("plugins", %{
        "det" => Map.merge(%{"profile" => profile}, group)
      })
      |> put_plugin(0, "det")
    end

    test "a model artifact that is not on disk fails the load, naming both" do
      map = argv_map("gone", %{}, @no_artifact_dir)

      assert {:error, errors} = Config.from_map(map)

      assert Enum.any?(
               errors,
               &(&1 =~
                   "profile gone: model artifact test/support/fixtures/models/not-here.onnx " <>
                     "does not exist")
             )
    end

    test "a profile naming no artifact for its backend fails the load" do
      map = argv_map("unnamed", %{}, @no_artifact_dir)

      assert {:error, errors} = Config.from_map(map)
      assert Enum.any?(errors, &(&1 =~ "profile unnamed names no model.onnx artifact"))
    end

    test "an artifact path that is a directory fails with 'not a regular file'" do
      dir = "test/support/fixtures/profiles/dir-artifact"
      map = argv_map("dir-artifact", %{}, dir)

      assert {:error, errors} = Config.from_map(map)
      assert Enum.any?(errors, &(&1 =~ "does not exist or is not a regular file"))
    end

    test "an unreferenced profile's artifact is not checked" do
      # Loaded, parsed, never attached to a group: the shipped dir will hold
      # board profiles for hardware this node does not have.
      map = Map.put(base_map(), "profile_dirs", [@no_artifact_dir])

      assert {:ok, config, _warnings} = Config.from_map(map)
      assert Map.has_key?(config.profiles, "gone")
    end

    test "a non-experimental profile on a non-ort backend is refused for the group that runs it" do
      map = argv_map("stable-rknn", %{"allow_experimental" => true})

      assert {:error, errors} = Config.from_map(map)
      assert Enum.any?(errors, &(&1 =~ "uses backend rknn, which is experimental"))
      assert Enum.any?(errors, &(&1 =~ "must declare experimental: true"))
    end

    test "an experimental profile still needs the group's acknowledgement" do
      map =
        base_map()
        |> Map.put("profile_dirs", ["test/support/fixtures/profiles/valid"])
        |> Map.put("plugins", %{"det" => %{"profile" => "rk-test"}})
        |> put_plugin(0, "det")

      assert {:error, errors} = Config.from_map(map)
      assert Enum.any?(errors, &(&1 =~ "set allow_experimental: true on this plugin group"))
    end

    test "both halves of the acknowledgement load, and the backend picks the artifact" do
      map =
        base_map()
        |> Map.put("profile_dirs", ["test/support/fixtures/profiles/valid"])
        |> Map.put("plugins", %{
          "det" => %{"profile" => "rk-test", "allow_experimental" => true}
        })
        |> put_plugin(0, "det")

      # The model comes from the rknn artifact, not the onnx one: the
      # backend picks the key.
      assert {:ok, config, _warnings} = Config.from_map(map)

      assert {:ok, %{model: "test/support/fixtures/models/stub.rknn", backend: "rknn"}} =
               Config.native_model_config(config)
    end

    test "allow_experimental must be a boolean" do
      map = argv_map("partial", %{"allow_experimental" => "yes"})

      assert {:error, errors} = Config.from_map(map)
      assert Enum.any?(errors, &(&1 =~ "plugin det: allow_experimental must be true or false"))
    end

    test "a labels file that is not on disk fails the load, naming both" do
      map = argv_map("missing-labels", %{}, "test/support/fixtures/profiles/labels")

      assert {:error, errors} = Config.from_map(map)

      assert Enum.any?(
               errors,
               &(&1 =~
                   "profile missing-labels: labels file " <>
                     "test/support/fixtures/models/not-here.names does not exist")
             )
    end

    test "an unreferenced profile's labels file is not checked either" do
      map = Map.put(base_map(), "profile_dirs", ["test/support/fixtures/profiles/labels"])

      assert {:ok, config, _warnings} = Config.from_map(map)
      assert Map.has_key?(config.profiles, "missing-labels")
    end
  end

  describe "profile expansion for the engine" do
    alias Cairn.Config.Profile
    alias Cairn.Native.Config, as: NativeConfig

    defp profile!(name) do
      assert {:ok, config, _warnings} = Config.from_map(argv_map(name))
      [%{profile: profile}] = config.plugin_groups
      profile
    end

    # `cameras` is a list of group references (nil = no plugin), `plugins` a
    # group name → profile name map.
    defp native_map(cameras, plugins) do
      base_map()
      |> Map.put("profile_dirs", [@argv_dir])
      |> Map.put(
        "plugins",
        Map.new(plugins, fn {group, profile} -> {group, %{"profile" => profile}} end)
      )
      |> Map.put(
        "cameras",
        Enum.with_index(cameras, fn group, index ->
          %{
            "id" => "cam_#{index}",
            "rtsp_url" => "rtsp://h/#{index}",
            "plugin" => group
          }
        end)
      )
    end

    test "an unset field is dropped, so the init config falls to the crate's own defaults" do
      assert Profile.native_config(profile!("partial")) == %{model: @stub_onnx, backend: "ort"}

      assert {:ok, config} = NativeConfig.normalize(Profile.native_config(profile!("partial")))
      assert config.decoder == "auto"
      assert config.sample_fps == 5
      assert config.model_profile == nil
    end

    test "a profile expands into model config only — scene knobs stay the operator's (D-P6)" do
      native = Profile.native_config(profile!("full"))

      refute Enum.any?([:min_score, :motion_json, :track_floor_json], &Map.has_key?(native, &1))

      # The boundary is enforced on both sides rather than merely observed here:
      # neither vocabulary accepts the other's keys.
      assert {:error, message} = NativeConfig.normalize(Map.put(native, :motion_json, "{}"))
      assert message =~ "unknown config keys: :motion_json"
      assert {:error, message} = NativeConfig.stream_params(%{model: "m.onnx", min_score: %{}})
      assert message =~ "unknown config keys: :model"
    end

    test "the six flags' validation still fires on the way to the engine" do
      profile = profile!("full")

      assert {:error, message} =
               NativeConfig.normalize(Map.put(Profile.native_config(profile), :sample_fps, 31))

      assert message =~ "sample_fps must be an integer in 1..30"

      assert {:error, message} =
               NativeConfig.normalize(Map.delete(Profile.native_config(profile), :model))

      assert message =~ "model is required"
    end

    test "a camera's profile is the engine's model config" do
      assert {:ok, config, _warnings} =
               Config.from_map(native_map(["det"], %{"det" => "full"}))

      assert Config.native_model_config(config) ==
               {:ok,
                %{
                  model: @stub_onnx,
                  model_profile: "yolox",
                  input_size: 416,
                  decoder: "auto",
                  labels: "test/support/fixtures/models/stub.names",
                  backend: "ort"
                }}
    end

    test "cameras on one profile agree, however many groups run it" do
      map = native_map(["a", "b"], %{"a" => "full", "b" => "full"})

      assert {:ok, config, _warnings} = Config.from_map(map)
      assert {:ok, %{model: @stub_onnx}} = Config.native_model_config(config)
    end

    test "cameras asking for different models fail the load, naming them" do
      map = native_map(["a", "b"], %{"a" => "full", "b" => "partial"})

      assert {:error, errors} = Config.from_map(map)
      assert Enum.any?(errors, &(&1 =~ "different models (full, partial)"))
      assert Enum.any?(errors, &(&1 =~ "loads one model for every camera"))
    end

    test "a camera on a group with no profile is refused at the group" do
      map =
        ["det"]
        |> native_map(%{"det" => "full"})
        |> Map.put("plugins", %{"det" => %{}})

      assert {:error, errors} = Config.from_map(map)
      assert Enum.any?(errors, &(&1 =~ "plugin det: profile is required"))
    end

    test "a camera with no plugin detects on nothing, and needs no profile" do
      map = native_map([nil, "det"], %{"det" => "full"})
      map = update_in(map, ["cameras", Access.at(0)], &Map.delete(&1, "plugin"))

      assert {:ok, config, _warnings} = Config.from_map(map)
      # cam_1 still configures the engine; cam_0 contributes nothing.
      assert {:ok, %{model: @stub_onnx}} = Config.native_model_config(config)
    end

    test "no plugin-bearing camera configures no engine" do
      map = native_map([nil], %{"det" => "full"})

      assert {:ok, config, _warnings} = Config.from_map(map)
      assert Config.native_model_config(config) == {:ok, nil}
    end
  end

  describe "sample_fps" do
    @sample_fps_bad_dir "test/support/fixtures/profiles/sample-fps-bad"

    alias Cairn.Config.Profile, as: SampleProfile

    defp sample_fps!(profile_name) do
      assert {:ok, config, _warnings} = Config.from_map(argv_map(profile_name))
      [%{profile: profile}] = config.plugin_groups
      Map.get(SampleProfile.native_config(profile), :sample_fps)
    end

    # D-P4: the band validates, it never emits. `full.yml` already declares
    # an fps_band with no sample_fps; an unset field is dropped from the
    # engine config so the crate's own default applies.
    test "absent sample_fps reaches no engine config, with no fps_band declared" do
      assert sample_fps!("partial") == nil
    end

    test "absent sample_fps reaches no engine config, even with fps_band declared" do
      assert sample_fps!("full") == nil
    end

    test "present sample_fps with no fps_band reaches the engine config" do
      assert sample_fps!("sample-fps") == 6
    end

    test "present sample_fps inside its own fps_band loads, no error" do
      assert sample_fps!("sample-fps-inband") == 6
    end

    test "sample_fps at its band's min edge loads (inclusive bound)" do
      assert sample_fps!("sample-fps-band-min") == 4
    end

    test "sample_fps at its band's max edge loads (inclusive bound)" do
      assert sample_fps!("sample-fps-band-max") == 8
    end

    test "a singleton fps_band [5, 5] admits sample_fps 5" do
      assert sample_fps!("sample-fps-singleton") == 5
    end

    test "sample_fps above its declared fps_band is a config error" do
      map = Map.put(base_map(), "profile_dirs", [@sample_fps_bad_dir])

      assert {:error, errors} = Config.from_map(map)

      assert Enum.any?(
               errors,
               &(&1 =~ "sample_fps 13 contradicts fps_band [8, 12]")
             )
    end

    test "sample_fps outside its declared fps_band is a config error naming both" do
      map = Map.put(base_map(), "profile_dirs", [@sample_fps_bad_dir])

      assert {:error, errors} = Config.from_map(map)

      assert Enum.any?(
               errors,
               &(&1 =~ "sample_fps 6 contradicts fps_band [8, 12]")
             )
    end

    test "sample_fps of 0 is a config error naming the bounds" do
      map = Map.put(base_map(), "profile_dirs", [@sample_fps_bad_dir])

      assert {:error, errors} = Config.from_map(map)
      assert Enum.any?(errors, &(&1 =~ "sample_fps must be an integer between 1 and 30, got 0"))
    end

    test "sample_fps of 31 is a config error naming the bounds" do
      map = Map.put(base_map(), "profile_dirs", [@sample_fps_bad_dir])

      assert {:error, errors} = Config.from_map(map)
      assert Enum.any?(errors, &(&1 =~ "sample_fps must be an integer between 1 and 30, got 31"))
    end

    test "a non-integer string sample_fps is a config error naming the bounds" do
      map = Map.put(base_map(), "profile_dirs", [@sample_fps_bad_dir])

      assert {:error, errors} = Config.from_map(map)

      assert Enum.any?(
               errors,
               &(&1 =~ ~s(sample_fps must be an integer between 1 and 30, got "fast"))
             )
    end

    test "a fractional sample_fps is a config error naming the bounds" do
      map = Map.put(base_map(), "profile_dirs", [@sample_fps_bad_dir])

      assert {:error, errors} = Config.from_map(map)

      assert Enum.any?(
               errors,
               &(&1 =~ "sample_fps must be an integer between 1 and 30, got 2.5")
             )
    end
  end

  describe "model ladder" do
    # An installed pack artifact only has to be a regular file at the path —
    # config load never opens it — so any fixture file stands in.
    @installed_pack "test/support/fixtures/models/stub.rknn"
    @absent_pack "test/support/fixtures/models/no-such-pack.onnx"
    @stub_names "test/support/fixtures/models/stub.names"

    # Three rungs bracketing the resolution matrix: an accurate 17-budget
    # Apache rung, a 26-budget pack rung (absent by default), and the
    # 75-budget capacity rung — coverage 75 / 1.875 = 40 = the declared max.
    defp ladder_yaml(opts \\ []) do
      """
      tier: 1
      model_profile: yolox
      labels: #{@stub_names}
      model_ladder:
        - model:
            onnx: #{@stub_onnx}
          model_profile: yolov8
          input_size: 640
          engine_budget: 17
        - model:
            onnx: #{Keyword.get(opts, :pack_model, @absent_pack)}
          input_size: 640
          engine_budget: 26
          pack: yolo26s
        - model:
            onnx: #{@stub_onnx}
          input_size: 416
          engine_budget: 75
      supported_cameras: 40
      """
    end

    defp ladder_map(n, dir) do
      base_map()
      |> Map.put("profile_dirs", [dir])
      |> Map.put("plugins", %{"det" => %{"profile" => "ladder"}})
      |> Map.put(
        "cameras",
        Enum.map(1..n//1, fn i ->
          %{"id" => "cam_#{i}", "rtsp_url" => "rtsp://h/#{i}", "plugin" => "det"}
        end)
      )
    end

    defp load_ladder(n, opts \\ []) do
      dir = tmp_profile_dir("ladder", ladder_yaml(opts))
      Config.from_map(ladder_map(n, dir))
    end

    defp resolved!(n, opts \\ []) do
      assert {:ok, config, warnings} = load_ladder(n, opts)
      [%{profile: profile}] = config.plugin_groups
      {config, profile, warnings}
    end

    test "a small fleet resolves the most accurate rung at the nominal cap" do
      {config, profile, _warnings} = resolved!(2)

      assert profile.resolved_rung.engine_budget == 17
      # Lowered: the rung's fields are what everything downstream reads —
      # the rung's own model_profile outranks the profile-level fallback.
      assert profile.input_size == 640
      assert profile.model_profile == "yolov8"
      # 2 × 7.5/s effective = 15 ≤ 17: the cap holds.
      assert profile.sample_fps == 10
      assert Config.sample_fps(config, hd(config.cameras)) == 10

      assert Config.native_model_config(config) ==
               {:ok,
                %{
                  model: @stub_onnx,
                  model_profile: "yolov8",
                  input_size: 640,
                  labels: @stub_names,
                  sample_fps: 10,
                  backend: "ort"
                }}
    end

    test "fleet_count: holds the ladder at a larger fleet" do
      dir = tmp_profile_dir("ladder", ladder_yaml())
      map = ladder_map(2, dir)

      assert {:ok, plain, _warnings} = Config.from_map(map)
      assert Config.sample_fps(plain, hd(plain.cameras)) == 10

      # The same two cameras resolved as if a third were still detecting:
      # 3 × 7.5 > 17, 3 × 5 = 15 ≤ 17. This is the loader holding N across a
      # skip so the survivors keep the rate they were already running.
      assert {:ok, held, _warnings} = Config.from_map(map, fleet_count: 3)
      assert Config.sample_fps(held, hd(held.cameras)) == 7
    end

    test "growing demand derives a lower rate before it leaves the rung" do
      # 8 × 1.875 = 15 ≤ 17 still fits the accurate rung, but only at the
      # floor: every intermediate nominal (3..10) quantizes to an effective
      # demand past 17/s on the 15 fps grid.
      {_config, profile, _warnings} = resolved!(8)

      assert profile.resolved_rung.engine_budget == 17
      assert profile.sample_fps == 2
    end

    test "an absent pack rung is skipped with a warning naming the pack" do
      # 10 × 1.875 = 18.75: past the 17 rung, and the 26-budget pack rung
      # would take it — absent, so resolution falls to the 75 rung and the
      # warning says what installing the pack buys.
      {_config, profile, warnings} = resolved!(10)

      assert profile.resolved_rung.engine_budget == 75
      assert profile.input_size == 416
      # Rung 3 names no model_profile of its own: profile-level fallback.
      assert profile.model_profile == "yolox"

      assert Enum.any?(
               warnings,
               &(&1 =~ "ladder rung 2 (pack yolo26s) skipped" and
                   &1 =~ "10 camera(s) would get this rung's model")
             )
    end

    test "a skipped pack rung that would not be selected is still warned, without the claim" do
      # At 2 cameras the accurate Apache rung wins outright; the pack could
      # not change the selection, and the warning must not say it would.
      {_config, _profile, warnings} = resolved!(2)

      warning = Enum.find(warnings, &(&1 =~ "ladder rung 2 (pack yolo26s) skipped"))
      assert warning
      refute warning =~ "would get"
    end

    test "the knee: ten cameras on the 75 budget derive the nominal cap, not a truncation" do
      # 10 × effective(10) = 10 × 7.5 = 75.0 — exactly the measured-uniform
      # ceiling cell. trunc(75/10) = 7 would quantize to 5.0/s effective and
      # leave a third of the budget unspent.
      {_config, profile, _warnings} = resolved!(10)
      assert profile.sample_fps == 10
    end

    test "an installed pack rung is an ordinary candidate" do
      {_config, profile, warnings} = resolved!(10, pack_model: @installed_pack)

      assert profile.resolved_rung.pack == "yolo26s"
      assert profile.resolved_rung.engine_budget == 26
      assert profile.input_size == 640
      assert profile.sample_fps == 2
      refute Enum.any?(warnings, &(&1 =~ "skipped"))
    end

    test "the declared boundary fits exactly — budgets divide against effective rates" do
      # 40 × 1.875 = 75.0 ≤ 75: the measured claim. Nominal arithmetic
      # (40 × 2 = 80) would refuse the fleet the campaign measured clean.
      {_config, profile, _warnings} = resolved!(40)

      assert profile.resolved_rung.engine_budget == 75
      assert profile.sample_fps == 2
    end

    test "past the claim the load fails naming N and the envelope" do
      # The claim bound speaks, not budget arithmetic: with an honest file
      # (coverage ≥ claim, enforced at parse) the bound is always the first
      # wall a growing fleet hits; `no_rung_fits` survives only as the
      # arithmetic-drift backstop behind it.
      assert {:error, errors} = load_ladder(41)

      assert Enum.any?(
               errors,
               &(&1 =~ "41 cameras exceed supported_cameras 40" and &1 =~ "support envelope")
             )
    end

    test "N counts cameras with detection configured, not the fleet (D-L1)" do
      # 41 cameras, one of them plugin-less: N = 40 still fits.
      dir = tmp_profile_dir("ladder", ladder_yaml())

      map =
        update_in(ladder_map(41, dir), ["cameras", Access.at(0)], &Map.delete(&1, "plugin"))

      assert {:ok, config, _warnings} = Config.from_map(map)
      [%{profile: profile}] = config.plugin_groups
      assert profile.resolved_rung.engine_budget == 75
    end

    test "two groups on one ladder profile agree — one resolution, one model" do
      dir = tmp_profile_dir("ladder", ladder_yaml())

      map =
        ladder_map(2, dir)
        |> Map.put("plugins", %{
          "a" => %{"profile" => "ladder"},
          "b" => %{"profile" => "ladder"}
        })
        |> put_in(["cameras", Access.at(0), "plugin"], "a")
        |> put_in(["cameras", Access.at(1), "plugin"], "b")

      assert {:ok, config, _warnings} = Config.from_map(map)
      assert {:ok, %{model: @stub_onnx, input_size: 640}} = Config.native_model_config(config)
    end

    test "a ladder group and a disagreeing single-model group refuse as today (risk #1)" do
      dir = tmp_profile_dir("ladder", ladder_yaml())

      File.write!(Path.join(dir, "solo.yml"), """
      model:
        onnx: #{@stub_onnx}
      model_profile: yolox
      input_size: 416
      labels: #{@stub_names}
      """)

      map =
        ladder_map(2, dir)
        |> Map.put("plugins", %{
          "det" => %{"profile" => "ladder"},
          "solo" => %{"profile" => "solo"}
        })
        |> put_in(["cameras", Access.at(1), "plugin"], "solo")

      assert {:error, errors} = Config.from_map(map)
      assert Enum.any?(errors, &(&1 =~ "different models (ladder, solo)"))
    end

    test "a spare group's ladder is not resolved against a fleet it does not serve" do
      # Three cameras detect on a single-model group; a spare group names a
      # 2-camera ladder no camera uses. Used-ness is a camera fact, not a
      # group fact: resolving the spare against N=3 would fail the load over
      # cameras that never touch it.
      dir =
        tmp_profile_dir("mini", """
        tier: 1
        model_profile: yolox
        labels: #{@stub_names}
        model_ladder:
          - model:
              onnx: #{@stub_onnx}
            input_size: 416
            engine_budget: 4
        supported_cameras: 2
        """)

      File.write!(Path.join(dir, "solo.yml"), """
      model:
        onnx: #{@stub_onnx}
      model_profile: yolox
      labels: #{@stub_names}
      """)

      map =
        ladder_map(3, dir)
        |> Map.put("plugins", %{
          "det" => %{"profile" => "solo"},
          "spare" => %{"profile" => "mini"}
        })

      assert {:ok, config, []} = Config.from_map(map)
      assert config.profiles["mini"].resolved_rung == nil
    end

    test "custom thresholds on a multi-rung ladder warn per camera (D-L3)" do
      # Score distributions shift between rungs and the rung follows fleet
      # size, so thresholds tuned once apply to models the operator never
      # tuned them on. cam_1 spoke (track tier); cam_2 did not — the warning
      # is per-camera and names what was customized.
      dir = tmp_profile_dir("ladder", ladder_yaml())

      map =
        update_in(ladder_map(2, dir), ["cameras", Access.at(0)], fn cam ->
          cam
          |> Map.put("track", %{"person" => %{"min_score" => 0.7}})
          |> Map.put("record", %{"person" => %{"min_score" => 0.8}})
        end)

      assert {:ok, _config, warnings} = Config.from_map(map)

      assert Enum.any?(
               warnings,
               &(&1 =~ "camera cam_1: track/record thresholds on a model-ladder profile" and
                   &1 =~ "shift between models")
             )

      refute Enum.any?(warnings, &(&1 =~ "camera cam_2: " and &1 =~ "model-ladder profile"))
    end

    test "default thresholds on a ladder stay quiet, as does a single-model profile" do
      {_config, _profile, warnings} = resolved!(2)
      refute Enum.any?(warnings, &(&1 =~ "model-ladder profile"))

      # The other quiet half the name claims: custom thresholds on a
      # SINGLE-MODEL profile are not the ladder's business.
      dir = tmp_profile_dir("ladder", ladder_yaml())

      File.write!(Path.join(dir, "solo.yml"), """
      model:
        onnx: #{@stub_onnx}
      model_profile: yolox
      labels: #{@stub_names}
      """)

      map =
        ladder_map(1, dir)
        |> Map.put("plugins", %{"det" => %{"profile" => "solo"}})
        |> update_in(["cameras", Access.at(0)], fn cam ->
          cam
          |> Map.put("track", %{"person" => %{"min_score" => 0.7}})
          |> Map.put("record", %{"person" => %{"min_score" => 0.8}})
        end)

      assert {:ok, _config, warnings} = Config.from_map(map)
      refute Enum.any?(warnings, &(&1 =~ "model-ladder profile"))
    end

    test "an unused ladder profile costs no probes, no warnings, no resolution" do
      # The pack artifact is absent and rung 3 exists only on disk checks a
      # used profile would run — no group names it, so nothing fires.
      dir = tmp_profile_dir("ladder", ladder_yaml())
      map = Map.put(base_map(), "profile_dirs", [dir])

      assert {:ok, config, []} = Config.from_map(map)
      assert config.profiles["ladder"].resolved_rung == nil
    end

    test "a missing non-pack rung artifact fails the load even when unselected (D-L2)" do
      # Two cameras select rung 1; rung 3's artifact is gone. A fleet edit
      # could select it tomorrow, so it must be loadable today.
      yaml =
        String.replace(
          ladder_yaml(),
          "- model:\n      onnx: #{@stub_onnx}\n    input_size: 416",
          "- model:\n      onnx: models/gone.onnx\n    input_size: 416"
        )

      dir = tmp_profile_dir("ladder", yaml)

      assert {:error, errors} = Config.from_map(ladder_map(2, dir))

      assert Enum.any?(
               errors,
               &(&1 =~ "ladder rung 3 model artifact models/gone.onnx does not exist")
             )
    end

    # -- parse refusals -----------------------------------------------------

    defp ladder_errors(yaml) do
      dir = tmp_profile_dir("ladder", yaml)
      assert {:error, errors} = Config.from_map(ladder_map(1, dir))
      errors
    end

    test "the ladder is mutually exclusive with the single-model fields, named together" do
      errors =
        ladder_errors("""
        #{ladder_yaml()}
        model:
          onnx: #{@stub_onnx}
        sample_fps: 5
        input_size: 640
        """)

      assert Enum.any?(
               errors,
               &(&1 =~ "model_ladder is mutually exclusive with model, sample_fps, input_size")
             )
    end

    test "a ladder without a tier is refused — resolution needs the floor" do
      errors = ladder_errors(String.replace(ladder_yaml(), "tier: 1\n", ""))
      assert Enum.any?(errors, &(&1 =~ "model_ladder requires tier:"))
    end

    test "a tier-2 ladder is refused until its rungs have a measured bar" do
      errors = ladder_errors(String.replace(ladder_yaml(), "tier: 1", "tier: 2"))
      assert Enum.any?(errors, &(&1 =~ "model_ladder is not available at tier 2"))
    end

    test "a rung an always-present rung shadows is refused naming both budgets" do
      errors =
        ladder_errors(String.replace(ladder_yaml(), "engine_budget: 26", "engine_budget: 17"))

      assert Enum.any?(
               errors,
               &(&1 =~ "no installation state" and &1 =~ "rung 2 budgets 17" and &1 =~ "17")
             )
    end

    # The yolox_m shape (qcs6490-tier1): a non-pack rung whose budget sits
    # below an earlier PACK rung's is reachable — it wins exactly when that
    # pack is absent — so one ladder serves both installation states.
    defp shadowed_ladder_yaml(pack_model) do
      """
      tier: 1
      model_profile: yolox
      labels: #{@stub_names}
      model_ladder:
        - model:
            onnx: #{pack_model}
          input_size: 640
          engine_budget: 26
          pack: yolo26s
        - model:
            onnx: #{@stub_onnx}
          input_size: 640
          engine_budget: 20
        - model:
            onnx: #{@stub_onnx}
          input_size: 416
          engine_budget: 75
      supported_cameras: 40
      """
    end

    test "pack rungs sharing an artifact share availability — the shadow holds" do
      # Same active-backend artifact path = installed and absent together, so
      # "the pack is absent" can never free the second rung from the first:
      # refused. The extra rknn entry on rung 2 must not fool the check —
      # availability is the ACTIVE backend's path, not the whole model map.
      yaml =
        String.replace(
          shadowed_ladder_yaml(@absent_pack),
          "engine_budget: 20\n",
          "engine_budget: 20\n    pack: yolo26s-twin\n"
        )
        |> String.replace(
          "onnx: #{@stub_onnx}",
          "onnx: #{@absent_pack}\n      rknn: #{@stub_onnx}",
          global: false
        )

      errors = ladder_errors(yaml)
      assert Enum.any?(errors, &(&1 =~ "no installation state" and &1 =~ "rung 2 budgets 20"))
    end

    test "a pack-shadowed rung is legal and wins exactly when the pack is absent" do
      # Pack absent: 10 cameras (demand 18.75) pass the pack skip and land
      # on the 20-budget rung — the accuracy the image itself carries.
      dir = tmp_profile_dir("ladder", shadowed_ladder_yaml(@absent_pack))
      assert {:ok, config, _warnings} = Config.from_map(ladder_map(10, dir))
      [%{profile: profile}] = config.plugin_groups
      assert profile.resolved_rung.engine_budget == 20

      # Pack installed: the 26-budget pack rung dominates and the shadowed
      # rung is never reached.
      dir = tmp_profile_dir("ladder", shadowed_ladder_yaml(@installed_pack))
      assert {:ok, config, _warnings} = Config.from_map(ladder_map(10, dir))
      [%{profile: profile}] = config.plugin_groups
      assert profile.resolved_rung.engine_budget == 26
    end

    test "a rung without this backend's artifact key is refused" do
      errors =
        ladder_errors(
          String.replace(ladder_yaml(), "onnx: #{@absent_pack}", "rknn: #{@absent_pack}")
        )

      assert Enum.any?(
               errors,
               &(&1 =~ "rung 2 names no model.onnx artifact for this profile's ort backend")
             )
    end

    test "a rung without input_size is refused — bare key included" do
      errors = ladder_errors(String.replace(ladder_yaml(), "    input_size: 416\n", ""))
      assert Enum.any?(errors, &(&1 =~ "model_ladder rung 3 must declare input_size"))

      # A bare `input_size:` parses to nil — declared in ink only, refused
      # the same way (the nil-means-absent rule).
      errors = ladder_errors(String.replace(ladder_yaml(), "input_size: 416", "input_size:"))
      assert Enum.any?(errors, &(&1 =~ "model_ladder rung 3 must declare input_size"))
    end

    test "a rung's engine_budget must be a positive measured number" do
      errors =
        ladder_errors(String.replace(ladder_yaml(), "engine_budget: 75", ~s(engine_budget: "75")))

      assert Enum.any?(
               errors,
               &(&1 =~ "rung 3 engine_budget must be a positive number of measured passes/s")
             )
    end

    test "a non-string pack is refused" do
      errors = ladder_errors(String.replace(ladder_yaml(), "pack: yolo26s", "pack: 5"))
      assert Enum.any?(errors, &(&1 =~ "rung 2 pack must be a pack name string, got 5"))
    end

    test "a rung's unknown model_profile is refused naming the menu" do
      errors =
        ladder_errors(
          String.replace(ladder_yaml(), "model_profile: yolov8", "model_profile: yolo99")
        )

      assert Enum.any?(errors, &(&1 =~ ~s(rung 1 unknown model_profile "yolo99")))
    end

    test "an empty ladder is refused" do
      errors =
        ladder_errors("""
        tier: 1
        model_ladder: []
        supported_cameras: 40
        """)

      assert Enum.any?(errors, &(&1 =~ "model_ladder must be a non-empty list of rungs"))
    end

    test "a ladder without supported_cameras is refused — the bound needs the claim" do
      errors = ladder_errors(String.replace(ladder_yaml(), ~r/supported_cameras: 40\n/, ""))

      assert Enum.any?(errors, &(&1 =~ "model_ladder requires supported_cameras"))
    end

    test "a {min, max} mapping is refused — the claim is a bare count" do
      # The design sketch's mapping shape; min never grew semantics and was
      # dropped rather than enforced, so the mapping fails loudly instead of
      # half-parsing.
      errors =
        ladder_errors(
          String.replace(ladder_yaml(), "supported_cameras: 40", "supported_cameras:\n  max: 40")
        )

      assert Enum.any?(
               errors,
               &(&1 =~ "supported_cameras must be the maximum camera count")
             )
    end

    test "a fleet past the claim is refused even with budget to spare" do
      # 30 cameras exceed a claim of 20 although the 75 rung covers 40 —
      # capacity arithmetic does not extend a claim nobody verified. Coverage
      # would flag 20-vs-40 the other way? No: coverage only demands the
      # non-pack rungs REACH the claim, and 40 ≥ 20 passes.
      dir =
        tmp_profile_dir(
          "ladder",
          String.replace(ladder_yaml(), "supported_cameras: 40", "supported_cameras: 20")
        )

      assert {:error, errors} = Config.from_map(ladder_map(30, dir))

      assert Enum.any?(
               errors,
               &(&1 =~ "30 cameras exceed supported_cameras 20" and &1 =~ "support envelope")
             )
    end

    test "supported_cameras on a single-model profile warns — nothing reads it (inert)" do
      dir =
        tmp_profile_dir("solo", """
        model:
          onnx: #{@stub_onnx}
        supported_cameras: 4
        """)

      map =
        base_map()
        |> Map.put("profile_dirs", [dir])
        |> Map.put("plugins", %{"det" => %{"profile" => "solo"}})
        |> put_plugin(0, "det")

      assert {:ok, _config, warnings} = Config.from_map(map)
      assert Enum.any?(warnings, &(&1 =~ "supported_cameras has no effect without model_ladder"))
    end

    test "a ladder leaning on packs for coverage is refused (Apache-complete, D-L2)" do
      # Largest non-pack budget 17 covers trunc(17 / 1.875) = 9 cameras;
      # claiming 40 makes the 75-budget pack rung load-bearing.
      errors =
        ladder_errors("""
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
            pack: nano-pack
        supported_cameras: 40
        """)

      assert Enum.any?(
               errors,
               &(&1 =~ "non-pack rungs alone cover ~9 cameras" and &1 =~ "Apache-complete")
             )
    end

    test "a bare pack: key is a non-pack rung — coverage still enforced" do
      # YAML `pack:` with no value parses to nil, which reads as absent (the
      # bare-`tracking:` rule). The trap this pins: a key-presence test would
      # either count the rung on the pack side or skip the whole coverage
      # invariant — 17 covers 9 cameras, so claiming 40 must still refuse.
      errors =
        ladder_errors("""
        tier: 1
        model_profile: yolox
        labels: #{@stub_names}
        model_ladder:
          - model:
              onnx: #{@stub_onnx}
            input_size: 640
            engine_budget: 17
            pack:
        supported_cameras: 40
        """)

      assert Enum.any?(
               errors,
               &(&1 =~ "non-pack rungs alone cover ~9 cameras" and &1 =~ "Apache-complete")
             )
    end

    test "a bare model_ladder: key says nothing — the profile stays single-model" do
      # Same nil-means-absent rule at the ladder key itself: the profile
      # loads on its `model:`, and supported_cameras warns inert like on any
      # single-model profile.
      dir =
        tmp_profile_dir("ladder", """
        model:
          onnx: #{@stub_onnx}
        model_ladder:
        supported_cameras: 4
        """)

      assert {:ok, config, warnings} = Config.from_map(ladder_map(1, dir))
      assert config.profiles["ladder"].model_ladder == nil
      assert Enum.any?(warnings, &(&1 =~ "supported_cameras has no effect without model_ladder"))
    end

    test "a ladder of only pack rungs is refused outright" do
      errors =
        ladder_errors("""
        tier: 1
        model_ladder:
          - model:
              onnx: #{@stub_onnx}
            input_size: 416
            engine_budget: 75
            pack: nano
        supported_cameras: 40
        """)

      assert Enum.any?(errors, &(&1 =~ "every model_ladder rung is a pack rung"))
    end
  end

  describe "backend capability table" do
    alias Cairn.Config.Profile

    @caps_dir "test/support/fixtures/profiles/caps"
    @caps_bad_dir "test/support/fixtures/profiles/caps-bad"

    defp caps_errors(dir) do
      assert {:error, errors} = Config.from_map(Map.put(base_map(), "profile_dirs", [dir]))
      errors
    end

    # The mirror itself. A row that drifts from
    # `BackendKind::capabilities` in plugins/cairn-detect/src/infer/backend.rs
    # is a change to what a profile may declare, not a refactor — the Rust side
    # has the same test over the same values.
    test "the table carries a row per backend, matching the plugin's own" do
      assert Profile.capabilities("ort") == %{
               artifact: "onnx",
               fused_nms: true,
               dynamic_shapes: true
             }

      # The documented near-collision: Rust reports `.onnx` as qnn's artifact
      # *format* (QNN is an onnxruntime execution provider) while the host keys
      # the file under `qnn:`, because a QDQ graph is a different file from the
      # fp32 export.
      assert Profile.capabilities("qnn") == %{
               artifact: "qnn",
               fused_nms: false,
               dynamic_shapes: false
             }

      assert Profile.capabilities("rknn") == %{
               artifact: "rknn",
               fused_nms: false,
               dynamic_shapes: false
             }
    end

    # The mechanical half of the pairing: read the Rust rows out of the source
    # and compare, so a coordinated Rust-side edit (table + its own test) still
    # trips something here. The regex failing to find three rows is itself the
    # tripwire — it means the Rust shape moved and the mirror needs re-pairing
    # by hand. `artifact` is deliberately not compared: the two sides disagree
    # for qnn by design (format vs `model:` key — see the table's comment).
    test "the capability booleans match the plugin's source, mechanically" do
      rust = File.read!("plugins/cairn-detect/src/infer/backend.rs")

      rows =
        Regex.scan(
          ~r/Self::(\w+) => Capabilities \{\s*supports_fused_nms: (\w+),\s*supports_dynamic_shapes: (\w+),/,
          rust
        )

      assert length(rows) == 3,
             "BackendKind::capabilities rows moved in backend.rs — re-pair the mirror " <>
               "(this regex and @backend_capabilities)"

      for [_, kind, fused, dynamic] <- rows do
        caps = kind |> String.downcase() |> Profile.capabilities()
        assert caps.fused_nms == (fused == "true"), "fused_nms drifted for #{kind}"
        assert caps.dynamic_shapes == (dynamic == "true"), "dynamic_shapes drifted for #{kind}"
      end
    end

    test "the family table resolves each family to its decode contract" do
      assert {"yolov8", _row} = Profile.family("yolo11")
      # Under yolov8, not yolov10: the runnable yolo26 exports are raw-head
      # (device-proven 2026-08-19; the catalog moved with the evidence).
      assert {"yolov8", _row} = Profile.family("yolo26")
      assert {"rfdetr", _row} = Profile.family("RF-DETR ")
      assert Profile.family("yolov12") == nil
    end

    # Rule 1, both sides. No shipped family fuses NMS into its export — every
    # catalog row is NMS-free or host-side — so the reject side cannot be built
    # from a real profile, and the rule is exercised against the row a future
    # catalog addition would have. Coverage composes: rule 2's fixture tests
    # run the public parse path through the same `check_capabilities/5`, so
    # the wiring is proven there and only this branch needs the direct call —
    # splitting the two rules into separate functions breaks that composition
    # and needs a public-path test for each half.
    test "a fused-NMS family is refused on a backend that cannot run the op" do
      acc = %{errors: [], warnings: []}
      fused = {"fusednet", %{families: [], nms: :fused, rknn_conversion: :documented}}

      assert %{errors: [error]} = Profile.check_capabilities(acc, "synthetic", "qnn", true, fused)
      assert error =~ "qnn backend requires an NMS-free family or host-side-NMS decode"
      assert error =~ "model_profile fusednet fuses the suppression op"

      assert %{errors: [_rknn_error]} =
               Profile.check_capabilities(acc, "synthetic", "rknn", true, fused)
    end

    test "the same family is accepted on ort, which implements the op" do
      acc = %{errors: [], warnings: []}
      fused = {"fusednet", %{families: [], nms: :fused, rknn_conversion: :documented}}

      assert Profile.check_capabilities(acc, "synthetic", "ort", true, fused) == acc
    end

    test "an NMS-free family and a host-side-NMS one both load on qnn" do
      assert {:ok, config, []} =
               Config.from_map(Map.put(base_map(), "profile_dirs", [@caps_dir]))

      assert config.profiles["qnn-nms-free"].model_profile == "yolov10"
      assert config.profiles["qnn-host-side-nms"].model_profile == "yolox"
    end

    # Rule 2. The rknn conversions the research does not document are shipped
    # only with the acknowledgement — both fixtures live in the dir above.
    test "rknn plus an undocumented conversion demands experimental: true" do
      errors = caps_errors(@caps_bad_dir)

      assert Enum.any?(
               errors,
               &(&1 =~
                   "profile rknn-unverified: rknn conversion is undocumented for " <>
                     "model_profile rfdetr")
             )

      assert Enum.any?(errors, &(&1 =~ "declare experimental: true"))
    end

    test "yolo26 does not inherit its contract row's documented rknn conversion" do
      # Conversion coverage is per FAMILY (the zoo documents through
      # YOLOv11); yolo26 shares yolov8's decode contract, not its claim.
      assert {"yolov8", %{rknn_conversion: :undocumented}} = Profile.family("yolo26")
      assert {"yolov8", %{rknn_conversion: :documented}} = Profile.family("yolov11")
    end

    test "the rknn refusal names the family the operator wrote, not the canonical" do
      errors = caps_errors(@caps_bad_dir)

      # "undocumented for yolov8" would contradict the table's own yolov8 row.
      assert Enum.any?(
               errors,
               &(&1 =~
                   "profile rknn-yolo26: rknn conversion is undocumented for " <>
                     "model_profile yolo26")
             )
    end

    # A truthy non-boolean is a type error AND not an acknowledgement: both
    # messages must surface, or the type error hides the actionable one.
    test "a non-boolean experimental does not satisfy the rknn rule" do
      errors = caps_errors(@caps_bad_dir)

      assert Enum.any?(
               errors,
               &(&1 =~ "profile rknn-truthy-experimental: experimental must be true or false")
             )

      assert Enum.any?(
               errors,
               &(&1 =~
                   "profile rknn-truthy-experimental: rknn conversion is undocumented for " <>
                     "model_profile rfdetr")
             )
    end

    test "the acknowledgement, or a documented family, satisfies the rule" do
      assert {:ok, config, []} =
               Config.from_map(Map.put(base_map(), "profile_dirs", [@caps_dir]))

      assert config.profiles["rknn-acknowledged"].experimental
      # yolo11 resolves to yolov8, whose conversion the model zoo documents:
      # no acknowledgement asked for by *this* rule.
      refute config.profiles["rknn-documented"].experimental
    end

    test "an unknown model_profile is refused, naming the menu it must come from" do
      errors = caps_errors(@caps_bad_dir)

      assert Enum.any?(
               errors,
               &(&1 =~ "profile bad-family: unknown model_profile \"yolov12\"")
             )

      assert Enum.any?(errors, &(&1 =~ "yolov8 (or yolov9, yolo11, yolov11, yolo26)"))
    end

    test "an unknown decoder is refused, and says which knob it is" do
      errors = caps_errors(@caps_bad_dir)

      assert Enum.any?(errors, &(&1 =~ "profile bad-decoder: unknown decoder \"cuda\""))
      assert Enum.any?(errors, &(&1 =~ "decoder: is the video decode path"))
    end
  end

  describe "built-in profiles" do
    # These four load on *every* config load, this suite's included, so a
    # broken one is a broken host and not just a broken board.
    test "the shipped dir parses clean and holds the four board profiles" do
      assert {:ok, config, []} = Config.from_map(base_map())

      assert Enum.sort(Map.keys(config.profiles)) == [
               "generic-ort",
               "qcs6490-tier1",
               "rk3566-lowfps",
               "rk3576"
             ]

      # Every single-model profile declares a band; a ladder profile cannot
      # (the ladder is the rate authority, D-L4) and derives instead.
      for {_name, profile} <- config.profiles do
        if profile.model_ladder do
          assert profile.fps_band == nil
        else
          assert [min, max] = profile.fps_band
          assert min > 0 and min <= max
        end
      end
    end

    test "generic-ort is the migration target: today's defaults, not experimental" do
      assert {:ok, config, []} = Config.from_map(base_map())
      profile = config.profiles["generic-ort"]

      refute profile.experimental
      assert profile.backend == "ort"
      assert profile.model_profile == "yolox"
      # The whole point of this one: adopting it changes nothing. The twin gate
      # is the no-profile stage list (D-P8); bbd and oru ship off.
      assert profile.stages == %{twin_mint: %{}}
      assert profile.max_unseen_ms == Config.default_max_unseen_ms()
      assert profile.max_live_tracks == Config.default_max_live_tracks()
      assert profile.stationary_after_ms == Config.default_stationary_after_ms()
    end

    test "the two rknn boards ship the full low-fps stage set, experimental" do
      assert {:ok, config, []} = Config.from_map(base_map())

      for name <- ["rk3566-lowfps", "rk3576"] do
        profile = config.profiles[name]
        assert profile.experimental, "#{name} runs a stubbed backend"
        assert profile.backend == "rknn"
        assert profile.stages == %{bbd: %{}, oru: %{}, twin_mint: %{}}
      end
    end

    test "qcs6490-tier1 is the shipped ladder: one list for every installation state" do
      assert {:ok, config, []} = Config.from_map(base_map())
      profile = config.profiles["qcs6490-tier1"]

      assert profile.experimental, "qnn has not soaked"
      assert profile.backend == "qnn"
      assert profile.tier == 1
      assert profile.supported_cameras == 40
      # Tier 1 runs no tracker, so the file says nothing about tracking —
      # the absent-block half of the presence rule.
      assert profile.stages == nil

      # Three yolo26 pack rungs interleaved with four baked Apache rungs
      # (the fixed-quantization rebuild, htp-verification-20260821):
      # yolox_m sits under yolo26s with a LOWER budget on purpose — the
      # pack dominates it when installed, and it carries mid fleets at
      # 46.9 mAP when only the image's own models exist (the reachability
      # rule; see check_budget_order). yolox_s/m/tiny now ship w8a8 (the
      # fixed recipe holds parity there and refunds 1.5-2.5x latency);
      # nano's budget is boundary-measured, the rest provisional until
      # their ladder runs (D-L6).
      assert [_m26, _s26, xm, xs, n416, tiny, nano] = profile.model_ladder

      assert Enum.map(profile.model_ladder, & &1.pack) ==
               ["yolo26m", "yolo26s", nil, nil, "yolo26n-416", nil, nil]

      assert xm.model == %{"qnn" => "models/yolox_m-qdq-a8.onnx"}
      assert xs.model == %{"qnn" => "models/yolox_s-qdq-a8.onnx"}

      assert Enum.map(profile.model_ladder, & &1.engine_budget) ==
               [18.5, 27.1, 25.0, 54.1, 73.5, 74, 75]

      # The crossovers, held with the same arithmetic resolution uses:
      # packs absent, yolox_m-a8 carries fleets through 13, yolox_s-a8
      # through 28, tiny through 39; 40 × 1.875 = 75 fits nano exactly
      # (its measured reach, = supported_cameras). The 26n-416 pack and
      # tiny share the through-39 boundary, so installing that pack buys
      # accuracy at 29-39 cameras, never reach. This pins the shipped
      # numbers to the record they came from.
      floor_rate = Cairn.Config.Profile.effective_rate(2)
      assert 13 * floor_rate < xm.engine_budget
      assert 14 * floor_rate > xm.engine_budget
      assert 28 * floor_rate < xs.engine_budget
      assert 29 * floor_rate > xs.engine_budget
      assert 39 * floor_rate < n416.engine_budget
      assert 40 * floor_rate > n416.engine_budget
      assert 39 * floor_rate < tiny.engine_budget
      assert 40 * floor_rate > tiny.engine_budget
      assert 40 * floor_rate <= nano.engine_budget
    end

    test "qcs6490-tier1 is the only shipped profile that names a decoder" do
      assert {:ok, config, []} = Config.from_map(base_map())

      # Naming one is a requirement on the membrane path, so it belongs only
      # where a decode path has been measured — Venus, spike 0.3. The other
      # three leave it unset and take `auto`'s fallback.
      assert config.profiles["qcs6490-tier1"].decoder == "v4l2"

      for name <- ["generic-ort", "rk3566-lowfps", "rk3576"] do
        assert config.profiles[name].decoder == nil, "#{name} names a decoder"
      end
    end

    # The D-L6 docs-honesty gate, running where `mix check` runs: a shipped
    # rung's budget is a measurement or it is marked provisional, and a file
    # whose NON-PACK rungs carry any provisional budget says DRAFT at the
    # top. Pack rungs are exempt from the DRAFT escalation (never from the
    # note): their artifacts do not exist until model-packs ships, so their
    # boundary runs cannot either — and the Apache-complete invariant keeps
    # them off the claim path. YAML comments never reach the parser, so the
    # provenance half reads the raw file — crude on purpose; it enforces
    # that the note exists, not that it is true — while pack-ness comes
    # from the parsed rungs, paired by order.
    test "every shipped ladder budget carries provenance; non-pack provisional ⇒ DRAFT" do
      for path <- Path.wildcard("priv/profiles/*.yml"),
          raw = File.read!(path),
          raw =~ "model_ladder:" do
        lines = String.split(raw, "\n")
        {:ok, parsed} = YamlElixir.read_from_file(path)
        pack_rung? = Enum.map(Map.fetch!(parsed, "model_ladder"), &(Map.get(&1, "pack") != nil))

        budget_indexes =
          for {line, index} <- Enum.with_index(lines),
              line =~ ~r/^\s+engine_budget:/,
              do: index

        assert length(budget_indexes) == length(pack_rung?),
               "#{path}: raw engine_budget lines and parsed rungs disagree — the gate's " <>
                 "order pairing is broken"

        # Each rung's window runs from just past the PREVIOUS rung's budget
        # line to its own — a neighbor's note can never satisfy it. `\b` so
        # "unmeasured" is not a provenance claim.
        provisional_nonpack =
          for {{index, prev}, pack?} <-
                Enum.zip(Enum.zip(budget_indexes, [-1 | budget_indexes]), pack_rung?) do
            window = lines |> Enum.slice((prev + 1)..index//1) |> Enum.join("\n")
            marked = window =~ ~r/\b(provisional|measured)\b/i

            assert marked,
                   "#{path}:#{index + 1} engine_budget has no measured/provisional " <>
                     "provenance note in its own rung's comment (D-L6)"

            window =~ ~r/\bprovisional\b/i and not pack?
          end

        assert provisional_nonpack != [], "#{path} declares a ladder with no budgets?"

        if Enum.any?(provisional_nonpack) do
          # At the top, enforced as stated: the marker is an operator-facing
          # banner, and a DRAFT buried in a rung comment is not one.
          top = raw |> String.split("\n") |> Enum.take(10) |> Enum.join("\n")

          assert top =~ "DRAFT",
                 "#{path} carries a provisional NON-PACK budget but no DRAFT marker in " <>
                   "the first 10 lines (D-L6 — the marker is a top-of-file banner)"
        end
      end
    end
  end

  describe "windows/2 and retention_days/3" do
    test "camera overrides win over globals" do
      {:ok, config, _} =
        base_map()
        |> update_in(["cameras"], fn [a, b] -> [Map.put(a, "pre_window_seconds", 9), b] end)
        |> Config.from_map()

      [cam_a, cam_b] = config.cameras
      assert Config.windows(config, cam_a) == %{pre: 9, post: 10, max: 300}
      assert Config.windows(config, cam_b) == %{pre: 5, post: 10, max: 300}
    end

    test "max_live_tracks defaults, is globally settable and per-camera overridable" do
      {:ok, defaults, _} = Config.from_map(base_map())
      [cam_a, _cam_b] = defaults.cameras
      assert defaults.max_live_tracks == 128
      assert Config.max_live_tracks(defaults, cam_a) == 128

      {:ok, config, _} =
        base_map()
        |> Map.put("tracking", %{"max_live_tracks" => 512})
        |> update_in(["cameras"], fn [a, b] -> [Map.put(a, "max_live_tracks", 32), b] end)
        |> Config.from_map()

      [cam_a, cam_b] = config.cameras
      assert Config.max_live_tracks(config, cam_a) == 32
      assert Config.max_live_tracks(config, cam_b) == 512
      assert Config.policy(config, cam_a).max_live_tracks == 32
    end

    test "max_unseen_ms defaults, is globally settable and per-camera overridable" do
      {:ok, defaults, _} = Config.from_map(base_map())
      [cam_a, _cam_b] = defaults.cameras
      assert defaults.max_unseen_ms == 3_000
      assert Config.max_unseen_ms(defaults, cam_a) == 3_000

      {:ok, config, _} =
        base_map()
        |> Map.put("tracking", %{"max_unseen_ms" => 5_000})
        |> update_in(["cameras"], fn [a, b] -> [Map.put(a, "max_unseen_ms", 800), b] end)
        |> Config.from_map()

      [cam_a, cam_b] = config.cameras
      assert Config.max_unseen_ms(config, cam_a) == 800
      assert Config.max_unseen_ms(config, cam_b) == 5_000

      # the ports hand the camera tracker windows and tracking as one map
      assert Config.policy(config, cam_a) == %{
               pre: 5,
               post: 10,
               max: 300,
               max_unseen_ms: 800,
               max_live_tracks: 128,
               stationary_after_ms: 10_000,
               bbd: false,
               oru: false,
               ocr: false,
               reid: false,
               track: nil,
               record: nil
             }
    end

    test "stationary_after_ms defaults, is globally settable and per-camera overridable" do
      {:ok, defaults, _} = Config.from_map(base_map())
      [cam_a, _cam_b] = defaults.cameras
      assert defaults.stationary_after_ms == 10_000
      assert Config.stationary_after_ms(defaults, cam_a) == 10_000

      {:ok, config, _} =
        base_map()
        |> Map.put("tracking", %{"stationary_after_ms" => 30_000})
        |> update_in(["cameras"], fn [a, b] -> [Map.put(a, "stationary_after_ms", 2_000), b] end)
        |> Config.from_map()

      [cam_a, cam_b] = config.cameras
      assert Config.stationary_after_ms(config, cam_a) == 2_000
      assert Config.stationary_after_ms(config, cam_b) == 30_000

      # the tracker reads it off the policy map, not off the config server
      assert Config.policy(config, cam_a).stationary_after_ms == 2_000
      assert Config.policy(config, cam_b).stationary_after_ms == 30_000
    end

    test "retention precedence: camera per-label > camera days > global per-label > global" do
      {:ok, config, _} =
        base_map()
        |> Map.put("retention", %{"days" => 10, "per_label" => %{"person" => 30}})
        |> update_in(["cameras"], fn [a, b] ->
          [Map.put(a, "retention", %{"days" => 3, "per_label" => %{"car" => 5}}), b]
        end)
        |> Config.from_map()

      [cam_a, cam_b] = config.cameras
      assert Config.retention_days(config, cam_a, "car") == 5
      assert Config.retention_days(config, cam_a, "person") == 3
      assert Config.retention_days(config, cam_b, "person") == 30
      assert Config.retention_days(config, cam_b, "car") == 10
    end
  end

  defp tmp_profile_dir(name, yaml) do
    dir = Path.join(System.tmp_dir!(), "cairn_profiles_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "#{name}.yml"), yaml)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp tmp_yaml(content) do
    path =
      Path.join(
        System.tmp_dir!(),
        "cairn_cfg_#{System.unique_integer([:positive])}.yml"
      )

    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
