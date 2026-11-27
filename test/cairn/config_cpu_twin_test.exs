# The CPU-twin rules (`Cairn.Config`'s `check_cpu_twin`), on `Cairn.TwinBoard`.
# Not async: the attached board is VM-global, and the menus
# `Cairn.Config.Profile` checks are read from it.
defmodule Cairn.ConfigCpuTwinTest do
  use ExUnit.Case, async: false

  alias Cairn.Config
  alias Cairn.Config.Profile
  alias Cairn.TwinBoard

  @stub "test/support/fixtures/models/stub.onnx"

  setup do
    TwinBoard.attach()
    assert Cairn.Board.module() == TwinBoard
    :ok
  end

  defp map(profile, dirs) do
    %{
      "data_dir" => "tmp/cfg_test",
      "profile_dirs" => dirs,
      "plugins" => %{"det" => %{"profile" => profile, "allow_experimental" => true}},
      "cameras" => [%{"id" => "cam_a", "rtsp_url" => "rtsp://h/1", "plugin" => "det"}]
    }
  end

  defp profile_dir(name, yaml) do
    dir = Path.join(System.tmp_dir!(), "cairn_twin_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "#{name}.yml"), yaml)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp accel(model) do
    """
    experimental: true
    backend: accel
    model:
    #{Enum.map_join(model, "\n", fn {key, path} -> "  #{key}: #{path}" end)}
    model_profile: yolox
    input_size: 416
    """
  end

  test "no twin named is an error" do
    dir = profile_dir("a", accel(accel: @stub))
    assert {:error, errors} = Config.from_map(map("a", [dir]))
    assert Enum.any?(errors, &(&1 =~ "but it names no model.onnx"))
  end

  test "a named twin file that is missing only warns" do
    dir = profile_dir("a", accel(accel: @stub, onnx: "gone.onnx"))
    assert {:ok, _config, warnings} = Config.from_map(map("a", [dir]))

    assert Enum.any?(
             warnings,
             &(&1 =~ "CPU twin gone.onnx does not exist" and &1 =~ "cannot be judged")
           )
  end

  test "a twin on disk passes and reaches the native config" do
    # Two files, so a twin that resolved to the accelerator's artifact fails.
    artifact =
      Path.join(System.tmp_dir!(), "cairn_twin_#{System.unique_integer([:positive])}.bin")

    File.write!(artifact, "")
    on_exit(fn -> File.rm(artifact) end)

    dir = profile_dir("a", accel(accel: artifact, onnx: @stub))
    assert {:ok, config, warnings} = Config.from_map(map("a", [dir]))
    refute Enum.any?(warnings, &(&1 =~ "CPU twin"))

    assert {:ok, %{model: ^artifact, cpu_twin: @stub, backend: "accel"}} =
             Config.native_model_config(config)
  end

  test "every ladder rung must name a twin" do
    dir =
      profile_dir("ladder", """
      tier: 1
      experimental: true
      backend: accel
      model_profile: yolox
      model_ladder:
        - model:
            accel: #{@stub}
          input_size: 640
          engine_budget: 17
        - model:
            accel: #{@stub}
            onnx: #{@stub}
          input_size: 416
          engine_budget: 75
      supported_cameras: 40
      """)

    assert {:error, errors} = Config.from_map(map("ladder", [dir]))
    assert Enum.any?(errors, &(&1 =~ "but ladder rung 1 names no model.onnx"))
    refute Enum.any?(errors, &(&1 =~ "ladder rung 2 names no model.onnx"))
  end

  test "a ladder's resolved rung naming a missing twin file only warns" do
    dir =
      profile_dir("ladder", """
      tier: 1
      experimental: true
      backend: accel
      model_profile: yolox
      model_ladder:
        - model:
            accel: #{@stub}
            onnx: gone.onnx
          input_size: 640
          engine_budget: 17
        - model:
            accel: #{@stub}
            onnx: #{@stub}
          input_size: 416
          engine_budget: 75
      supported_cameras: 4
      """)

    assert {:ok, _config, warnings} = Config.from_map(map("ladder", [dir]))
    assert Enum.any?(warnings, &(&1 =~ "CPU twin gone.onnx does not exist"))
  end

  describe "a fetched twin" do
    @twin_sha String.duplicate("ef", 32)
    # Any regular file other than the twin will do for the accelerator's.
    @accel_file "test/support/fixtures/profiles/argv/full.yml"

    defp fetched_yaml(backend \\ "accel") do
      """
      tier: 1
      experimental: true
      backend: #{backend}
      model_profile: yolox
      model_ladder:
        - model:
            #{Profile.artifact_key(backend)}: #{@accel_file}
          twin_sha256: #{String.upcase(@twin_sha)}
          twin_url: https://h/models/t.onnx
          input_size: 416
          engine_budget: 75
      supported_cameras: 4
      """
    end

    defp fetched_load(yaml, state) do
      Process.put(:release_dir, profile_dir("fetched", yaml))
      Config.from_map(map("fetched", []), board: TwinBoard, artifact: state)
    end

    defp twin_store(@twin_sha), do: {:ok, @stub}

    test "in the store, it is the twin the native config carries" do
      assert {:ok, config, warnings} = fetched_load(fetched_yaml(), &twin_store/1)
      refute Enum.any?(warnings, &(&1 =~ "CPU twin"))

      assert {:ok, %{model: @accel_file, cpu_twin: @stub, backend: "accel"}} =
               Config.native_model_config(config)
    end

    test "not in the store yet, it names the twin: the rung loads, with a warning" do
      assert {:ok, config, [warning]} =
               fetched_load(fetched_yaml(), fn _sha256 -> {:missing, nil} end)

      assert warning ==
               "profile fetched: CPU twin t.onnx is not downloaded yet — accel will load and " <>
                 "detect, but its health cannot be judged against the CPU until it is"

      assert {:ok, native} = Config.native_model_config(config)
      assert native.model == @accel_file
      refute Map.has_key?(native, :cpu_twin)
    end

    test "malformed, or a second source for the twin, is refused" do
      for {from, to, error} <- [
            {"twin_url: https://h/models/t.onnx", "",
             "needs both twin_sha256: and twin_url: — the file is fetched"},
            {String.upcase(@twin_sha), "abc",
             ~s(twin_sha256 must be 64 hex characters, got "abc")},
            {"https://h/models/t", "http://h/models/t", "twin_url must be an https URL"},
            {"engine_budget: 75", "engine_budget: 75\n    pack: p",
             "is a pack rung, and a pack is installed by hand"},
            {"accel: #{@accel_file}", "accel: #{@accel_file}\n      onnx: #{@stub}",
             "names both a CPU twin to fetch and model.onnx — two sources for one twin"}
          ] do
        yaml = String.replace(fetched_yaml(), from, to)
        assert {:error, errors} = fetched_load(yaml, &twin_store/1)
        assert Enum.any?(errors, &(&1 =~ "profile fetched: model_ladder rung 1 " <> error)), error
      end
    end

    test "outside the release's own profiles it is refused" do
      dir = profile_dir("fetched", fetched_yaml())
      assert {:error, errors} = Config.from_map(map("fetched", [dir]), artifact: &twin_store/1)

      assert Enum.any?(
               errors,
               &(&1 =~ "rung 1 names a file to fetch (twin_sha256:/twin_url:), which only")
             )
    end

    # The third state beside refused and effective: valid, and doing nothing.
    test "on a backend that uses no twin it is inert, and warns" do
      for backend <- ~w(qnn ort) do
        assert {:ok, config, warnings} = fetched_load(fetched_yaml(backend), &twin_store/1)

        assert ("profile fetched: model_ladder rung 1 names a CPU twin to fetch " <>
                  "(twin_sha256:/twin_url:), but the #{backend} backend uses no CPU twin — " <>
                  "the file is fetched for nothing; drop both keys") in warnings

        assert {:ok, native} = Config.native_model_config(config)
        assert native.model == @accel_file
        refute Map.has_key?(native, :cpu_twin)
      end
    end
  end
end
