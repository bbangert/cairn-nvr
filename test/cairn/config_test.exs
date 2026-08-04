defmodule Cairn.ConfigTest do
  use ExUnit.Case, async: true

  alias Cairn.Config

  @valid_fixture "test/support/fixtures/configs/valid.yml"
  @groups_fixture "test/support/fixtures/configs/plugin_groups.yml"

  defp base_map do
    %{
      "data_dir" => "tmp/cfg_test",
      "udp" => %{"base_port" => 17_000, "range" => 20},
      "cameras" => [
        %{"id" => "cam_a", "rtsp_url" => "rtsp://h/1"},
        %{"id" => "cam_b", "rtsp_url" => "rtsp://h/2"}
      ]
    }
  end

  describe "load/1" do
    test "loads the valid fixture" do
      assert {:ok, %Config{} = config, warnings} = Config.load(@valid_fixture)
      assert config.stall_seconds == 15
      assert config.udp_base_port == 17_000
      assert [%Config.Camera{id: "cam_a"} = cam_a, %Config.Camera{id: "cam_b"}] = config.cameras
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

    test "missing udp section is an error" do
      map = Map.delete(base_map(), "udp")
      assert {:error, errors} = Config.from_map(map)
      assert Enum.any?(errors, &(&1 =~ "udp.base_port and udp.range are required"))
    end

    test "exhausted udp range is an error" do
      map = put_in(base_map(), ["udp", "range"], 3)
      assert {:error, errors} = Config.from_map(map)
      assert Enum.any?(errors, &(&1 =~ "udp range exhausted"))
    end

    test "udp range overflowing the port space is an error" do
      map = %{base_map() | "udp" => %{"base_port" => 65_000, "range" => 5_000}}
      assert {:error, errors} = Config.from_map(map)
      assert Enum.any?(errors, &(&1 =~ "must fit below 65536"))
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

      # every camera or none: the matcher is one decision for the fleet, so
      # unlike the three bounds beside it there is no per-camera form of it
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
      assert Enum.any?(warnings, &(&1 =~ ~s(unknown key "typo_key" in camera #0)))
    end

    test "plugin accepts a multi-token command string or an argv list" do
      map =
        update_in(base_map(), ["cameras"], fn [a, b] ->
          [Map.put(a, "plugin", "python3 plug.py --x"), Map.put(b, "plugin", ["./plug"])]
        end)

      assert {:ok, config, _} = Config.from_map(map)

      assert [
               %{plugin: {:inline, ["python3", "plug.py", "--x"]}},
               %{plugin: {:inline, ["./plug"]}}
             ] = config.cameras
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
    defp with_plugins(map, plugins), do: Map.put(map, "plugins", plugins)

    defp put_plugin(map, index, plugin) do
      update_in(map, ["cameras"], fn cams ->
        List.update_at(cams, index, &Map.put(&1, "plugin", plugin))
      end)
    end

    test "loads the plugin group fixture" do
      assert {:ok, config, []} = Config.load(@groups_fixture)

      assert [detect, spare] = config.plugin_groups
      assert detect.name == "detect"
      assert detect.command == ["./cairn-detect", "--model", "m.onnx"]
      assert spare.command == ["./spare-plugin"]
      assert spare.members == []

      assert [
               %{id: "cam_a", plugin: {:group, "detect"}},
               %{id: "cam_b", plugin: {:inline, ["python3", "plug.py", "--x"]}},
               %{id: "cam_c", plugin: {:group, "detect"}}
             ] = config.cameras

      assert detect.members == [
               %{id: "cam_a", udp_port: 17_000, min_score: %{"default" => 0.5, "person" => 0.6}},
               %{id: "cam_c", udp_port: 17_008, min_score: %{"default" => 0.5}}
             ]
    end

    test "a single-token plugin string references a named group" do
      map =
        base_map()
        |> with_plugins(%{"detect" => %{"command" => "./detect --model m.onnx"}})
        |> put_plugin(0, "detect")

      assert {:ok, config, []} = Config.from_map(map)
      assert [%{plugin: {:group, "detect"}}, %{plugin: nil}] = config.cameras

      assert [%{name: "detect", command: ["./detect", "--model", "m.onnx"]}] =
               config.plugin_groups
    end

    test "a single-token plugin string with no matching group is an error" do
      map = put_plugin(base_map(), 0, "detekt")

      assert {:error, errors} = Config.from_map(map)
      assert Enum.any?(errors, &(&1 =~ ~s(camera cam_a: unknown plugin "detekt")))
    end

    test "a one-element list is the inline escape hatch, not a group reference" do
      map = put_plugin(base_map(), 0, ["./my-plugin"])

      assert {:ok, config, []} = Config.from_map(map)
      assert [%{plugin: {:inline, ["./my-plugin"]}}, _] = config.cameras
    end

    test "members carry each referencing camera's port and min_score in config order" do
      map =
        base_map()
        |> with_plugins(%{"detect" => %{"command" => ["./detect"]}})
        |> put_plugin(1, "detect")
        |> put_plugin(0, "detect")
        |> update_in(["cameras"], fn [a, b] ->
          [Map.put(a, "min_score", %{"person" => 0.7}), b]
        end)

      assert {:ok, config, []} = Config.from_map(map)
      assert [%{members: members}] = config.plugin_groups

      assert members == [
               %{id: "cam_a", udp_port: 17_000, min_score: %{"default" => 0.5, "person" => 0.7}},
               %{id: "cam_b", udp_port: 17_004, min_score: %{"default" => 0.5}}
             ]
    end

    test "a group nobody references parses with empty members" do
      map = with_plugins(base_map(), %{"detect" => %{"command" => ["./detect"]}})

      assert {:ok, config, []} = Config.from_map(map)
      assert [%{name: "detect", members: []}] = config.plugin_groups
    end

    test "command is required and must be a string or argv list" do
      assert {:error, errors} = Config.from_map(with_plugins(base_map(), %{"detect" => %{}}))
      assert Enum.any?(errors, &(&1 =~ "plugin detect: command is required"))

      assert {:error, errors} =
               Config.from_map(with_plugins(base_map(), %{"detect" => %{"command" => 42}}))

      assert Enum.any?(errors, &(&1 =~ "plugin detect: command must be"))
    end

    test "a camera referencing a group that failed to parse gets no extra error" do
      map =
        base_map()
        |> with_plugins(%{"detect" => %{"command" => 42}})
        |> put_plugin(0, "detect")

      assert {:error, errors} = Config.from_map(map)
      assert Enum.any?(errors, &(&1 =~ "plugin detect: command must be"))
      refute Enum.any?(errors, &(&1 =~ "unknown plugin"))
    end

    test "an invalid group name is an error" do
      map = with_plugins(base_map(), %{"Detect Group" => %{"command" => ["./detect"]}})

      assert {:error, errors} = Config.from_map(map)
      assert Enum.any?(errors, &(&1 =~ "plugin Detect Group: name must be lowercase"))
    end

    test "a group name colliding with a camera id is an error" do
      map = with_plugins(base_map(), %{"cam_a" => %{"command" => ["./detect"]}})

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
          "detect" => %{"command" => ["./detect"], "typo_key" => true}
        })

      assert {:ok, _config, warnings} = Config.from_map(map)
      assert Enum.any?(warnings, &(&1 =~ ~s(unknown key "typo_key" in plugin detect)))
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
