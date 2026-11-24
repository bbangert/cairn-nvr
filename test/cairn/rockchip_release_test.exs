# The base as a Rockchip release sees it; compiled only under
# CAIRN_BOARD=rockchip, where `Cairn.Rockchip.Board` exists.
if Cairn.Board.module() == Cairn.Rockchip.Board do
  defmodule Cairn.RockchipReleaseTest do
    use ExUnit.Case, async: true

    import Membrane.ChildrenSpec

    alias Cairn.Config
    alias Cairn.Config.Profile
    alias Cairn.Native.Drain
    alias Cairn.Pipeline.DetectChain
    alias Cairn.Rockchip.{DecodeScale, Download}
    alias Cairn.Stage.Capabilities

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

    # yolox, a proven rknn conversion, so `experimental:` is the D-P10 gate
    # alone.
    defp rknn(model, experimental \\ true) do
      """
      experimental: #{experimental}
      backend: rknn
      model:
      #{Enum.map_join(model, "\n", fn {key, path} -> "  #{key}: #{path}" end)}
      model_profile: yolox
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

    # The generic board's rows are paired in config_test.exs; this is rknn's,
    # whose descriptor is the board crate's.
    test "the rknn capability booleans match the board crate's source" do
      [[_, fused, dynamic]] =
        Regex.scan(
          ~r/name: "rknn",\s*capabilities: Capabilities \{\s*supports_fused_nms: (\w+),\s*supports_dynamic_shapes: (\w+),/,
          File.read!("boards/cairn_rockchip/native/cairn_rockchip/src/rknn.rs")
        )

      caps = Profile.capabilities("rknn")
      assert caps.fused_nms == (fused == "true")
      assert caps.dynamic_shapes == (dynamic == "true")
    end

    # A key the base never asks about (an alias, a misspelling) is a dead
    # verdict, and a contract the board omits reads as unlisted, not measured.
    test "rknn's verdicts are keyed by exactly the base's decode contracts" do
      %{conversions: %{contracts: contracts}} = Profile.capabilities("rknn")
      assert Enum.sort(Map.keys(contracts)) == Enum.sort(Profile.contracts())
    end

    test "the release's profiles are the base's and the board's; qcs6490-tier1 is not one" do
      assert {:ok, config, []} = Config.from_map(%{"data_dir" => "tmp/cfg_test"})
      assert Enum.sort(Map.keys(config.profiles)) == ["generic-ort", "rk3566-tier1"]

      assert {:error, errors} = Config.from_map(map("qcs6490-tier1", []))
      assert Enum.any?(errors, &(&1 =~ ~s(unknown profile "qcs6490-tier1")))
    end

    @rungs [
      {"c61524bca75d6f5df3fd255c8f27b5eaca544c94cbd05d4ce835a82a48733282", "yolox_s_640_i8.rknn",
       "models/yolox_s.onnx", 640, 7.5},
      {"832df464bc84259d8d612bb7e9d4f6dd8573acb94f9847e051cce4c438c78304",
       "yolox_tiny_416_i8.rknn", "models/yolox_tiny.onnx", 416, 16.875}
    ]

    test "rk3566-tier1: two fetched Apache rungs with their twins, and the store's set" do
      assert {:ok, config, []} = Config.from_map(%{"data_dir" => "tmp/cfg_test"})
      profile = config.profiles["rk3566-tier1"]
      assert %{tier: 1, experimental: true, backend: "rknn", decoder: "rkmpp"} = profile
      assert profile.supported_cameras == 9
      url = "https://github.com/bbangert/cairn-nvr/releases/download/models-rk3566-1/"
      assert length(profile.model_ladder) == length(@rungs)

      for {rung, {sha256, file, twin, size, budget}} <- Enum.zip(profile.model_ladder, @rungs) do
        assert %{sha256: ^sha256, model: %{"onnx" => ^twin}, input_size: ^size} = rung
        assert rung.url == url <> file
        assert rung.engine_budget == budget
        assert rung.pack == nil
      end

      entries = Profile.fetch_entries(Config.release_profile_dirs())

      assert Enum.map(entries, &{&1.sha256, &1.name}) ==
               Enum.map(@rungs, &{elem(&1, 0), elem(&1, 1)})
    end

    test "rk3566-tier1 runs on the store's files, and is refused while one is missing" do
      verified = fn _sha256 -> {:ok, @stub_rknn} end

      assert {:ok, config, _warnings} =
               Config.from_map(map("rk3566-tier1", []), artifact: verified)

      assert {:ok, %{model: @stub_rknn, cpu_twin: "models/yolox_s.onnx", input_size: 640}} =
               Config.native_model_config(config)

      [{tiny416, _, _, _, _}] = tl(@rungs)

      state = fn sha256 ->
        if sha256 == tiny416, do: {:missing, "timeout"}, else: verified.(sha256)
      end

      assert {:error, [error]} = Config.from_map(map("rk3566-tier1", []), artifact: state)

      assert error ==
               "plugin det: profile rk3566-tier1 needs yolox_tiny_416_i8.rknn (ladder rung 2), " <>
                 "not downloaded yet: the last fetch failed: timeout — the download is retried " <>
                 "until it succeeds; no camera can run on this group before then"
    end

    # Rule 2 of the capability table, which needs rknn on the menu.
    test "rknn plus an unproven conversion demands experimental: true, as a boolean" do
      dir = "test/support/fixtures/profiles/rknn-caps-bad"
      assert {:error, errors} = Config.from_map(map("none", [dir]))

      rknn_errors = Enum.filter(errors, &(&1 =~ "is not a proven rknn conversion"))

      # The family the operator wrote, not its canonical: yolo11 and yolo26
      # are refused by name, not as "yolov8". The reasons' own wording is
      # pinned in the board library's suite.
      expected =
        for {where, family} <- [
              {"rknn-rfdetr", "rfdetr"},
              {"rknn-truthy-experimental", "rfdetr"},
              {"rknn-yolov10", "yolov10"},
              {"rknn-whole-head", "yolo11"},
              {"rknn-yolo26", "yolo26"},
              # a rung's own family, over a profile whose family is proven
              {"rknn-rung: model_ladder rung 1", "yolo11"}
            ] do
          {canonical, _row} = Profile.family(family)
          {:unproven, why} = Capabilities.conversion(Profile.capabilities("rknn"), canonical)

          "profile #{where}: model_profile #{family} is not a proven rknn conversion: " <>
            "#{why} — experimental: true loads it regardless " <>
            "(measurements: tools/rknn-export/README.md)"
        end

      assert Enum.sort(rknn_errors) == Enum.sort(expected)

      assert Enum.any?(
               errors,
               &(&1 =~ "profile rknn-truthy-experimental: experimental must be true or false")
             )

      fused = {"fusednet", "fusednet", %{families: [], nms: :fused}}
      acc = %{errors: [], warnings: []}
      rknn = {"rknn", Profile.capabilities("rknn")}

      assert %{errors: [error]} = Profile.check_capabilities(acc, "profile s", rknn, true, fused)

      assert error =~ "profile s: rknn backend requires an NMS-free family or host-side-NMS"
    end

    test "a proven conversion satisfies rule 2; the acknowledgement loads with its reason" do
      dir = "test/support/fixtures/profiles/rknn-caps"

      assert {:ok, config, [warning]} =
               Config.from_map(%{"data_dir" => "tmp/cfg_test", "profile_dirs" => [dir]})

      assert warning =~
               "profile rknn-acknowledged: experimental: true loads model_profile yolov10, " <>
                 "which is not a proven rknn conversion: its end-to-end output detects nothing"

      assert config.profiles["rknn-acknowledged"].experimental

      for name <- ~w(rknn-yolox rknn-split rknn-yolo26split) do
        refute config.profiles[name].experimental, name
      end
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

    test "rknn needs experimental twice (D-P10)" do
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
