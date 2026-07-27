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

    test "per-camera max_unseen_ms overrides are validated" do
      map =
        update_in(base_map(), ["cameras"], fn [a, b] ->
          [Map.put(a, "max_unseen_ms", "soon"), b]
        end)

      assert {:error, errors} = Config.from_map(map)
      assert Enum.any?(errors, &(&1 =~ "camera cam_a: max_unseen_ms must be 100..3600000"))
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

      # the ports hand the aggregator windows and tracking as one map
      assert Config.policy(config, cam_a) == %{pre: 5, post: 10, max: 300, max_unseen_ms: 800}
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
