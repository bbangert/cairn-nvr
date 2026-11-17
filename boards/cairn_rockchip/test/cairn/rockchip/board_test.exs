defmodule Cairn.Rockchip.BoardTest do
  # The `:generic` env and `CAIRN_RKNN_LIBRARY` are VM-global.
  use ExUnit.Case, async: false

  alias Cairn.Rockchip.Board
  alias Cairn.Rockchip.Native

  # This suite has no base app, so stand-in atoms play the base's libraries.
  @generic [decoder: :base_decoder, engine: %{module: :base_engine, canary: "base-canary"}]

  setup do
    previous = Application.fetch_env(:cairn_rockchip, :generic)
    Application.put_env(:cairn_rockchip, :generic, @generic)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:cairn_rockchip, :generic, value)
        :error -> Application.delete_env(:cairn_rockchip, :generic)
      end
    end)
  end

  test "rknn is this library's engine and probe; everything else is the base's" do
    assert Board.engine("rknn") == %{module: Native, canary: "cairn-rockchip-probe"}
    assert Board.engine("ort") == @generic[:engine]
    assert Board.decoder_backend("sw") == :base_decoder
    assert Board.decoder_backend("auto") == :base_decoder
  end

  test "the menus offer no qnn and no hardware decoder, and only rknn needs a twin" do
    assert Board.decoders() == ~w(auto sw)
    assert Map.keys(Board.backends()) == ~w(ort rknn)
    assert Board.backends()["rknn"].cpu_twin
    refute Board.backends()["ort"].cpu_twin
  end

  test "the chain is the context's generic steps, unchanged" do
    steps = [:decode_step, :infer_step]
    assert Board.detect_chain(%{generic: steps}) == steps
  end

  describe "preflight" do
    setup do
      previous = System.get_env("CAIRN_RKNN_LIBRARY")

      on_exit(fn ->
        if previous,
          do: System.put_env("CAIRN_RKNN_LIBRARY", previous),
          else: System.delete_env("CAIRN_RKNN_LIBRARY")
      end)
    end

    test "rknn is unusable, with the reason, when the board NIF did not load" do
      System.delete_env("CAIRN_RKNN_LIBRARY")

      # CI never builds the library, so this is the branch it reaches.
      if Native.available?() do
        assert Board.preflight() == %{decoders: %{}, backends: %{}}
      else
        assert %{decoders: decoders, backends: %{"rknn" => reason}} = Board.preflight()
        assert decoders == %{}
        assert reason =~ "the board NIF did not load"

        System.put_env("CAIRN_RKNN_LIBRARY", "")
        assert [nif, library] = String.split(Board.preflight().backends["rknn"], "; ")
        assert nif =~ "the board NIF did not load"
        assert library =~ "CAIRN_RKNN_LIBRARY is set but empty"
      end
    end

    test "a CAIRN_RKNN_LIBRARY that is not a regular file is named" do
      dir = Path.join(System.tmp_dir!(), "cairn_rk_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      System.put_env("CAIRN_RKNN_LIBRARY", dir)
      assert %{backends: %{"rknn" => reason}} = Board.preflight()
      assert reason =~ "CAIRN_RKNN_LIBRARY names #{dir}, which is not a regular file"

      file = Path.join(dir, "librknnrt.so")
      File.write!(file, "")
      System.put_env("CAIRN_RKNN_LIBRARY", file)
      refute (Board.preflight().backends["rknn"] || "") =~ "CAIRN_RKNN_LIBRARY"
    end
  end
end
