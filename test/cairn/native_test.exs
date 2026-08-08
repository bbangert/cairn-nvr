defmodule Cairn.NativeTest do
  use ExUnit.Case, async: true

  alias Cairn.Native
  alias Cairn.Native.Canary
  alias Cairn.Native.Config

  @fake_detect Path.absname("test/support/fake_detect.sh")

  describe "loading" do
    # The whole point of the arrangement: CI runs this suite without the Rust
    # toolchain, so the module has to still be there to say so.
    test "the module is usable whether or not the library loaded" do
      assert is_boolean(Native.available?())
      assert Native.available?() == (Native.load_error() == nil)
    end

    test "a call with no library raises a recognisable error instead of undef" do
      if Native.available?() do
        assert Native.load_error() == nil
      else
        assert_raise ErlangError, fn -> Native.close_stream(make_ref()) end
      end
    end
  end

  describe "Config.normalize/1" do
    test "fills in every key the crate's decode requires" do
      assert {:ok, config} = Config.normalize(model: "m.onnx")

      assert config == %{
               model: "m.onnx",
               backend: "ort",
               model_profile: nil,
               input_size: nil,
               labels: nil,
               allow_label_mismatch: false,
               embedder_model: nil,
               decoder: "auto",
               sample_fps: 5,
               qnn: %{
                 library: nil,
                 soc_model: nil,
                 htp_arch: nil,
                 performance_mode: nil,
                 vtcm_mb: nil
               }
             }
    end

    test "flag values may be spelled as atoms" do
      assert {:ok, config} = Config.normalize(%{model: "m.onnx", backend: :qnn, decoder: :vaapi})
      assert config.backend == "qnn"
      assert config.decoder == "vaapi"
    end

    test "a model is required and a typo is refused rather than defaulted" do
      assert {:error, message} = Config.normalize(backend: "qnn")
      assert message =~ "model"

      assert {:error, message} = Config.normalize(model: "m.onnx", backedn: "qnn")
      assert message =~ ":backedn"

      assert {:error, message} = Config.normalize(model: "m.onnx", qnn: %{socmodel: 35})
      assert message =~ ":socmodel"
    end
  end

  describe "Config.to_argv/1" do
    test "is the flag spelling of the same config" do
      {:ok, config} =
        Config.normalize(
          model: "m.onnx",
          backend: "qnn",
          input_size: "640x352",
          model_profile: "yolox",
          allow_label_mismatch: true,
          qnn: %{library: "libqnn.so", soc_model: 35}
        )

      argv = Config.to_argv(config)

      assert ["--model", "m.onnx" | _] = argv
      assert "--allow-label-mismatch" in argv
      assert value_of(argv, "--backend") == "qnn"
      assert value_of(argv, "--input-size") == "640x352"
      assert value_of(argv, "--model-profile") == "yolox"
      assert value_of(argv, "--qnn-library") == "libqnn.so"
      assert value_of(argv, "--qnn-soc-model") == "35"
      # absent stays absent rather than becoming an empty flag value
      refute "--labels" in argv
      refute "--embedder-model" in argv
    end

    defp value_of(argv, flag) do
      case Enum.find_index(argv, &(&1 == flag)) do
        nil -> nil
        index -> Enum.at(argv, index + 1)
      end
    end
  end

  describe "Canary.probe/2" do
    setup do
      {:ok, config} = Config.normalize(model: "good.onnx")
      %{config: config}
    end

    test "a clean probe load passes", %{config: config} do
      assert Canary.probe(config, binary: @fake_detect, timeout_ms: 5_000) == :ok
    end

    test "a model that will not open fails with what the process said", %{config: config} do
      {:ok, config} = Config.normalize(%{config | model: "bad.onnx"})

      assert {:error, message} = Canary.probe(config, binary: @fake_detect, timeout_ms: 5_000)
      assert message =~ "status 1"
      assert message =~ "no such file"
    end

    test "a probe that never says ready is ended by the timeout", %{config: config} do
      {:ok, config} = Config.normalize(%{config | model: "hang.onnx"})

      assert {:error, message} = Canary.probe(config, binary: @fake_detect, timeout_ms: 200)
      assert message =~ "timeout"
    end

    test "no binary and disabled are skips, not failures", %{config: config} do
      assert Canary.probe(config, enabled: false) == {:skipped, :disabled}
      assert Canary.probe(config, binary: "/nonexistent/cairn-detect") == {:skipped, :no_binary}
    end
  end
end
