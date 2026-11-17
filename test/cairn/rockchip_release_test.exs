# The base as a Rockchip release sees it; compiled only under
# CAIRN_BOARD=rockchip, where `Cairn.Rockchip.Board` exists.
if Cairn.Board.module() == Cairn.Rockchip.Board do
  defmodule Cairn.RockchipReleaseTest do
    use ExUnit.Case, async: true

    import Membrane.ChildrenSpec

    alias Cairn.Config
    alias Cairn.Native.Drain
    alias Cairn.Pipeline.DetectChain
    alias Cairn.Rockchip.{DecodeScale, Download}

    @stub_rknn "test/support/fixtures/models/stub.rknn"
    @stub_onnx "test/support/fixtures/models/stub.onnx"

    defp map(profile, dirs, group \\ %{"allow_experimental" => true}) do
      %{
        "data_dir" => "tmp/cfg_test",
        "profile_dirs" => dirs,
        "plugins" => %{"det" => Map.put(group, "profile", profile)},
        "cameras" => [%{"id" => "cam_a", "rtsp_url" => "rtsp://h/1", "plugin" => "det"}]
      }
    end

    defp profile_dir(name, yaml) do
      dir = Path.join(System.tmp_dir!(), "cairn_rk_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "#{name}.yml"), yaml)
      on_exit(fn -> File.rm_rf(dir) end)
      dir
    end

    # yolov8, whose rknn conversion is documented, so `experimental:` is the
    # D-P10 gate alone.
    defp rknn(model, experimental \\ true) do
      """
      experimental: #{experimental}
      backend: rknn
      model:
      #{Enum.map_join(model, "\n", fn {key, path} -> "  #{key}: #{path}" end)}
      model_profile: yolov8
      input_size: 416
      """
    end

    defp twin_error?(errors), do: Enum.any?(errors, &(&1 =~ "names no model.onnx"))

    test "the base reaches the board's libraries, and drains all three" do
      board = Cairn.Board.module()

      assert board.engine("rknn") == %{
               module: Cairn.Rockchip.Native,
               canary: "cairn-rockchip-probe"
             }

      assert board.engine("ort") == %{module: CairnOrt, canary: "cairn-detect"}
      assert board.decoder_backend("sw") == Cairn.Native
      assert board.decoder_backend("rkmpp") == Cairn.Rockchip.Native
      assert Drain.libraries() == [CairnOrt, Cairn.Rockchip.Native, Cairn.Native]
    end

    test "an rkmpp camera decodes on the board, opened through the base's host" do
      detect = [stream_params: %{min_score: %{}, motion_json: nil}, decoder: "rkmpp"]
      spec = DetectChain.build(get_child(:tagger), %{id: "cam_a"}, detect)
      children = Map.new(spec.children, fn {name, element, _opts} -> {name, element} end)

      assert %DecodeScale{host: Cairn.Native.Host} = children.decoder
      assert %Download{} = children.download
    end

    test "qnn is refused by name of board" do
      dir = profile_dir("q", "experimental: true\nbackend: qnn\nmodel:\n  qnn: #{@stub_onnx}\n")

      assert {:error, errors} = Config.from_map(map("q", [dir]))

      assert Enum.any?(
               errors,
               &(&1 =~ ~s(unknown backend "qnn" — the rockchip board provides ort or rknn))
             )
    end

    test "the shipped qnn profile is skipped, so naming it is an unknown profile" do
      assert {:ok, config, _warnings} = Config.from_map(%{"data_dir" => "tmp/cfg_test"})
      refute Map.has_key?(config.profiles, "qcs6490-tier1")
      assert Map.has_key?(config.profiles, "rk3566-lowfps")

      assert {:error, errors} = Config.from_map(map("qcs6490-tier1", []))
      assert Enum.any?(errors, &(&1 =~ ~s(unknown profile "qcs6490-tier1")))
    end

    test "a shipped rknn profile without a twin is a twin error" do
      assert {:error, errors} = Config.from_map(map("rk3566-lowfps", []))
      assert twin_error?(errors)
    end

    test "rknn needs a twin: none is an error, a missing file a warning" do
      dir = profile_dir("rk", rknn(rknn: @stub_rknn))
      assert {:error, errors} = Config.from_map(map("rk", [dir]))
      assert twin_error?(errors)

      dir = profile_dir("rk", rknn(rknn: @stub_rknn, onnx: "gone.onnx"))
      assert {:ok, _config, warnings} = Config.from_map(map("rk", [dir]))

      assert Enum.any?(
               warnings,
               &(&1 =~ "CPU twin gone.onnx does not exist" and &1 =~ "cannot be judged")
             )

      dir = profile_dir("rk", rknn(rknn: @stub_rknn, onnx: @stub_onnx))
      assert {:ok, config, warnings} = Config.from_map(map("rk", [dir]))
      refute Enum.any?(warnings, &(&1 =~ "CPU twin"))

      assert {:ok, %{model: @stub_rknn, cpu_twin: @stub_onnx, backend: "rknn"}} =
               Config.native_model_config(config)
    end

    test "an ort profile carries no twin and needs none" do
      dir = profile_dir("o", "backend: ort\nmodel:\n  onnx: #{@stub_onnx}\n")
      assert {:ok, config, _warnings} = Config.from_map(map("o", [dir], %{}))
      assert {:ok, native} = Config.native_model_config(config)
      refute Map.has_key?(native, :cpu_twin)
    end

    test "every ladder rung must name a twin" do
      dir =
        profile_dir("ladder", """
        tier: 1
        experimental: true
        backend: rknn
        model_profile: yolox
        model_ladder:
          - model:
              rknn: #{@stub_rknn}
            input_size: 640
            engine_budget: 17
          - model:
              rknn: #{@stub_rknn}
              onnx: #{@stub_onnx}
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
        backend: rknn
        model_profile: yolox
        model_ladder:
          - model:
              rknn: #{@stub_rknn}
              onnx: gone.onnx
            input_size: 640
            engine_budget: 17
          - model:
              rknn: #{@stub_rknn}
              onnx: #{@stub_onnx}
            input_size: 416
            engine_budget: 75
        supported_cameras: 4
        """)

      assert {:ok, _config, warnings} = Config.from_map(map("ladder", [dir]))
      assert Enum.any?(warnings, &(&1 =~ "CPU twin gone.onnx does not exist"))
    end

    test "D-P10 is unchanged: rknn still needs experimental twice" do
      dir = profile_dir("rk", rknn([rknn: @stub_rknn, onnx: @stub_onnx], false))
      assert {:error, errors} = Config.from_map(map("rk", [dir]))
      assert Enum.any?(errors, &(&1 =~ "must declare experimental: true"))

      dir = profile_dir("rk", rknn(rknn: @stub_rknn, onnx: @stub_onnx))
      assert {:error, errors} = Config.from_map(map("rk", [dir], %{}))
      assert Enum.any?(errors, &(&1 =~ "set allow_experimental: true on this plugin group"))
    end
  end
end

# Outside the `if`, so a CAIRN_BOARD the build did not honour fails here
# instead of compiling the suite above to zero tests.
defmodule Cairn.ReleaseBoardTest do
  use ExUnit.Case, async: true

  test "the compiled board is the one CAIRN_BOARD names" do
    assert Cairn.Board.module().name() == System.get_env("CAIRN_BOARD", "generic")
  end
end
