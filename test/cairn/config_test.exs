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
        "det" => %{"command" => "./p", "profile" => profile, "allow_experimental" => true}
      })
      |> put_plugin(0, "det")
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

  describe "profile argv expansion" do
    @argv_dir "test/support/fixtures/profiles/argv"
    @no_artifact_dir "test/support/fixtures/profiles/no-artifact"
    @stub_onnx "test/support/fixtures/models/stub.onnx"
    @stub_names "test/support/fixtures/models/stub.names"

    defp argv_map(profile, group \\ %{}, dir \\ @argv_dir) do
      base_map()
      |> Map.put("profile_dirs", [dir])
      |> Map.put("plugins", %{
        "det" => Map.merge(%{"command" => "./p", "profile" => profile}, group)
      })
      |> put_plugin(0, "det")
    end

    defp command!(map) do
      assert {:ok, config, _warnings} = Config.from_map(map)
      [%{command: command}] = config.plugin_groups
      command
    end

    test "a full profile expands to every model flag, after the operator's argv" do
      assert command!(argv_map("full")) == [
               "./p",
               "--model",
               @stub_onnx,
               "--model-profile",
               "yolox",
               "--input-size",
               "416",
               "--decoder",
               "auto",
               "--labels",
               @stub_names
             ]
    end

    test "a partial profile emits only the flags it set" do
      assert command!(argv_map("partial")) == ["./p", "--model", @stub_onnx]
    end

    test "the expansion follows the operator's own flags" do
      map = argv_map("partial", %{"command" => ["./p", "--motion-json", "{}"]})

      assert command!(map) == ["./p", "--motion-json", "{}", "--model", @stub_onnx]
    end

    test "an unprofiled group's command is left alone, model flags and all" do
      map =
        base_map()
        |> Map.put("plugins", %{"det" => %{"command" => "./p --model m.onnx --input-size 416"}})
        |> put_plugin(0, "det")

      assert command!(map) == ["./p", "--model", "m.onnx", "--input-size", "416"]
    end

    test "a profiled group carrying a model flag itself fails the load (D-P4)" do
      map = argv_map("partial", %{"command" => "./p --input-size 416"})

      assert {:error, errors} = Config.from_map(map)
      assert Enum.any?(errors, &(&1 =~ "plugin det: command carries --input-size"))
      assert Enum.any?(errors, &(&1 =~ "which profile partial owns"))
    end

    test "the D-P4 check sees the --flag=value form too" do
      map = argv_map("partial", %{"command" => ["./p", "--labels=coco.names"]})

      assert {:error, errors} = Config.from_map(map)
      assert Enum.any?(errors, &(&1 =~ "command carries --labels"))
    end

    test "the D-P4 check sees a flag embedded in a shell-wrapped composite token" do
      map =
        argv_map("partial", %{
          "command" => ["/bin/sh", "-c", "exec cairn-detect --model /opt/m.onnx"]
        })

      assert {:error, errors} = Config.from_map(map)
      assert Enum.any?(errors, &(&1 =~ "plugin det: command carries --model"))
    end

    test "the D-P4 check sees a quoted flag inside a shell-wrapped composite token" do
      map =
        argv_map("partial", %{
          "command" => ["/bin/sh", "-c", "exec cairn-detect '--model' /opt/m.onnx"]
        })

      assert {:error, errors} = Config.from_map(map)
      assert Enum.any?(errors, &(&1 =~ "plugin det: command carries --model"))
    end

    test "a flag string embedded mid-path does not trip D-P4" do
      map = argv_map("partial", %{"command" => ["./p", "/opt/--model/x"]})

      assert {:ok, _config, _warnings} = Config.from_map(map)
    end

    test "the D-P4 boundary match does not bleed --model into a --model-profile-only command" do
      map = argv_map("partial", %{"command" => ["./p", "--model-profile"]})

      assert {:error, errors} = Config.from_map(map)
      assert Enum.count(errors, &(&1 =~ "command carries")) == 1
      assert Enum.any?(errors, &(&1 =~ "command carries --model-profile"))
    end

    test "the operator's own JSON flags are not model flags (D-P6)" do
      map =
        argv_map("partial", %{
          "command" => ["./p", "--motion-json", "{}", "--track-floor-json", "{}"]
        })

      assert command!(map) == [
               "./p",
               "--motion-json",
               "{}",
               "--track-floor-json",
               "{}",
               "--model",
               @stub_onnx
             ]
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

    test "a stubbed backend is refused for the group that runs it" do
      map = argv_map("stable-rknn", %{"allow_experimental" => true})

      assert {:error, errors} = Config.from_map(map)
      assert Enum.any?(errors, &(&1 =~ "uses backend rknn, which is not yet implemented"))
      assert Enum.any?(errors, &(&1 =~ "must declare experimental: true"))
    end

    test "an experimental profile still needs the group's acknowledgement" do
      map =
        base_map()
        |> Map.put("profile_dirs", ["test/support/fixtures/profiles/valid"])
        |> Map.put("plugins", %{"det" => %{"command" => "./p", "profile" => "rk-test"}})
        |> put_plugin(0, "det")

      assert {:error, errors} = Config.from_map(map)
      assert Enum.any?(errors, &(&1 =~ "set allow_experimental: true on this plugin group"))
    end

    test "both halves of the acknowledgement load, and expand" do
      map =
        base_map()
        |> Map.put("profile_dirs", ["test/support/fixtures/profiles/valid"])
        |> Map.put("plugins", %{
          "det" => %{"command" => "./p", "profile" => "rk-test", "allow_experimental" => true}
        })
        |> put_plugin(0, "det")

      # `--model` comes from the rknn artifact, not the onnx one: the backend
      # picks the key.
      assert command!(map) == [
               "./p",
               "--model",
               "test/support/fixtures/models/stub.rknn",
               "--model-profile",
               "yolox",
               "--input-size",
               "416",
               "--decoder",
               "auto",
               "--labels",
               @stub_names
             ]
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

    test "the family table resolves the catalog's aliases to their family" do
      assert {"yolov8", _row} = Profile.family("yolo11")
      assert {"yolov10", _row} = Profile.family("yolo26")
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
      fused = {"fusednet", %{aliases: [], nms: :fused, rknn_conversion: :documented}}

      assert %{errors: [error]} = Profile.check_capabilities(acc, "synthetic", "qnn", true, fused)
      assert error =~ "qnn backend requires an NMS-free family or host-side-NMS decode"
      assert error =~ "model_profile fusednet fuses the suppression op"

      assert %{errors: [_rknn_error]} =
               Profile.check_capabilities(acc, "synthetic", "rknn", true, fused)
    end

    test "the same family is accepted on ort, which implements the op" do
      acc = %{errors: [], warnings: []}
      fused = {"fusednet", %{aliases: [], nms: :fused, rknn_conversion: :documented}}

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

      assert Enum.any?(errors, &(&1 =~ "yolov8 (or yolov9, yolo11, yolov11)"))
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
               "qcs6490",
               "rk3566-lowfps",
               "rk3576"
             ]

      # Every band is declared rather than measured, but every profile has one.
      for {_name, profile} <- config.profiles do
        assert [min, max] = profile.fps_band
        assert min > 0 and min <= max
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

    test "qcs6490 is NMS-free with every stage delisted, twin gate included" do
      assert {:ok, config, []} = Config.from_map(base_map())
      profile = config.profiles["qcs6490"]

      assert profile.experimental
      assert profile.backend == "qnn"
      assert profile.model_profile == "yolov10"
      # Present-but-empty is the presence-semantics half that matters here: the
      # block speaks, and what it says is "nothing runs" (D-P8).
      assert profile.stages == %{}
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
