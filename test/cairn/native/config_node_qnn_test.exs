defmodule Cairn.Native.ConfigNodeQnnTest do
  # async: false — these tests set the `:qnn` application env, which every
  # concurrent `Config.normalize/1` call would see.
  use ExUnit.Case, async: false

  alias Cairn.Native.Config

  setup do
    # Restore rather than delete: runtime.exs legitimately sets this key at
    # boot on a machine with CAIRN_QNN_* exported, and wiping it would leak
    # into every later suite.
    prior = Application.fetch_env(:cairn, :qnn)

    on_exit(fn ->
      case prior do
        {:ok, value} -> Application.put_env(:cairn, :qnn, value)
        :error -> Application.delete_env(:cairn, :qnn)
      end
    end)
  end

  test "node-level qnn facts reach a config that says nothing about qnn" do
    Application.put_env(:cairn, :qnn, library: "/opt/qnn/ep.so", soc_model: 35, htp_arch: 68)

    assert {:ok, config} = Config.normalize(model: "m.onnx", backend: "qnn")
    assert config.qnn.library == "/opt/qnn/ep.so"
    assert config.qnn.soc_model == 35
    assert config.qnn.htp_arch == 68
    # Untouched keys keep their defaults.
    assert config.qnn.performance_mode == nil
  end

  test "an explicit qnn map wins over the node env, key by key" do
    Application.put_env(:cairn, :qnn, library: "/opt/qnn/ep.so", soc_model: 35)

    assert {:ok, config} =
             Config.normalize(model: "m.onnx", backend: "qnn", qnn: %{library: "/data/ep.so"})

    assert config.qnn.library == "/data/ep.so"
    assert config.qnn.soc_model == 35
  end

  test "a typo'd key in the node env is an error, not a silently inert setting" do
    Application.put_env(:cairn, :qnn, libary: "/opt/qnn/ep.so")

    assert {:error, message} = Config.normalize(model: "m.onnx", backend: "qnn")
    assert message =~ "libary"
  end

  test "node env types go through the same coercion as config-file values" do
    Application.put_env(:cairn, :qnn, soc_model: "35")

    assert {:error, message} = Config.normalize(model: "m.onnx", backend: "qnn")
    assert message =~ "qnn.soc_model must be an integer"
  end

  test "the node env rides along inert on a CPU backend" do
    # The crate reads qnn options only under `--backend qnn`
    # (plugins/cairn-detect/src/main.rs qnn_options), so an ort config in a
    # container that sets CAIRN_QNN_* must still normalize — the values are
    # carried, deliberately unread.
    Application.put_env(:cairn, :qnn, library: "/opt/qnn/ep.so", soc_model: 35)

    assert {:ok, config} = Config.normalize(model: "m.onnx", backend: "ort")
    assert config.qnn.library == "/opt/qnn/ep.so"
  end

  describe "node_qnn_from_env/1 (the runtime.exs parse)" do
    test "set variables become the keyword, unset ones are skipped" do
      env = %{
        "CAIRN_QNN_LIBRARY" => "/opt/qnn/ep.so",
        "CAIRN_QNN_SOC_MODEL" => "35",
        "CAIRN_QNN_HTP_ARCH" => "68",
        "UNRELATED" => "x"
      }

      assert Config.node_qnn_from_env(env) ==
               [library: "/opt/qnn/ep.so", soc_model: 35, htp_arch: 68]
    end

    test "a bare environment yields an empty keyword" do
      assert Config.node_qnn_from_env(%{}) == []
    end

    test "a malformed integer fails naming the variable and the value" do
      assert_raise ArgumentError, ~r/CAIRN_QNN_SOC_MODEL.*"abc"/, fn ->
        Config.node_qnn_from_env(%{"CAIRN_QNN_SOC_MODEL" => "abc"})
      end
    end
  end
end
