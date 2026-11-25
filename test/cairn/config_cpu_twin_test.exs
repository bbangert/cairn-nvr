# The CPU-twin rules (`Cairn.Config`'s `check_cpu_twin`). No board in this
# tree has a `cpu_twin: true` backend, so the test attaches one. Not async:
# the attached board is VM-global, and the menus `Cairn.Config.Profile`
# checks are read from it.
defmodule Cairn.ConfigCpuTwinTest do
  use ExUnit.Case, async: false

  alias Cairn.Board.Loader
  alias Cairn.Config

  # The generic board plus one accelerator backend whose artifact the CPU
  # baseline cannot run.
  defmodule TwinBoard do
    alias Cairn.Board.Generic

    def name, do: "twin"

    def backends do
      Map.put(Generic.backends(), "accel", %{
        artifact: "accel",
        fused_nms: true,
        dynamic_shapes: false,
        cpu_twin: true,
        experimental: true
      })
    end

    defdelegate detect_chain(context), to: Generic
    defdelegate decoders, to: Generic
    defdelegate decoder_backend(decoder, base), to: Generic
    defdelegate engine(backend, base), to: Generic
    defdelegate preflight, to: Generic
    defdelegate artifacts(context), to: Generic
    defdelegate profiles_dir, to: Generic
  end

  @key {Loader, :board}
  @stub "test/support/fixtures/models/stub.onnx"

  setup do
    before = :persistent_term.get(@key, :unset)

    on_exit(fn ->
      if before == :unset,
        do: :persistent_term.erase(@key),
        else: :persistent_term.put(@key, before)
    end)

    :persistent_term.put(@key, {:attached, %{board: TwinBoard}})
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
    dir = profile_dir("a", accel(accel: @stub, onnx: @stub))
    assert {:ok, config, warnings} = Config.from_map(map("a", [dir]))
    refute Enum.any?(warnings, &(&1 =~ "CPU twin"))

    assert {:ok, %{model: @stub, cpu_twin: @stub, backend: "accel"}} =
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
end
