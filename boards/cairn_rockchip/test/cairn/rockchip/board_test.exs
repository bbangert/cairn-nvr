defmodule Cairn.Rockchip.BoardTest do
  # The `:generic` env and `CAIRN_RKNN_LIBRARY` are VM-global.
  use ExUnit.Case, async: false

  alias Cairn.Rockchip.{Board, DecodeScale, Download, Native}
  alias Cairn.Stage.{Chain, Step}

  # This suite has no base app, so stand-in atoms play the base's libraries.
  @generic [
    decoder: :base_decoder,
    host: :base_host,
    engine: %{module: :base_engine, canary: "base-canary"}
  ]

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
    assert Board.decoder_backend("rkmpp") == Native
  end

  test "the menus offer no qnn, rkmpp only by name, and only rknn needs a twin" do
    assert Board.decoders() == ~w(auto sw rkmpp)
    assert Map.keys(Board.backends()) == ~w(ort rknn)
    assert Board.backends()["rknn"].cpu_twin
    refute Board.backends()["ort"].cpu_twin
  end

  defp generic(gate?) do
    step = &%Step{name: &1, element: &1, covers: &2, input: &3, output: &4}
    gate = if gate?, do: [step.(:motion_gate, [:motion], :rgb, :rgb)], else: []

    [step.(:decoder, [:decode, :scale], :h264, :rgb)] ++
      gate ++ [step.(:infer, [:infer], :rgb, :detections)]
  end

  defp context(decoder, gate?) do
    %{
      camera_id: "cam",
      stream_params: %{min_score: %{}, motion_json: if(gate?, do: "{}")},
      decoder: decoder,
      motion: nil,
      generic: generic(gate?)
    }
  end

  test "any decoder but rkmpp gets the generic steps, unchanged" do
    for decoder <- ["sw", "auto", nil],
        do: assert(Board.detect_chain(context(decoder, true)) == generic(true))
  end

  test "rkmpp decodes and scales on the board, then downloads, gated or not" do
    for gate? <- [false, true] do
      steps = Board.detect_chain(context("rkmpp", gate?))
      assert :ok = Chain.validate(steps, Chain.required(gate?))
      assert [%Step{name: :decoder, element: decode}, %Step{element: %Download{}} | rest] = steps
      assert rest == tl(generic(gate?))

      assert %DecodeScale{camera_id: "cam", host: :base_host, stream_params: params} = decode
      assert params.motion_json == nil
    end
  end

  describe "preflight" do
    setup do
      previous = System.get_env("CAIRN_RKNN_LIBRARY")
      Application.put_env(:cairn_rockchip, :devices, [__ENV__.file])

      on_exit(fn ->
        Application.delete_env(:cairn_rockchip, :devices)

        if previous,
          do: System.put_env("CAIRN_RKNN_LIBRARY", previous),
          else: System.delete_env("CAIRN_RKNN_LIBRARY")
      end)
    end

    test "rkmpp names each missing device and the NIF, in one reason" do
      Application.put_env(:cairn_rockchip, :devices, ["/nonexistent/mpp", __ENV__.file, "/nope"])
      reasons = String.split(Board.preflight().decoders["rkmpp"], "; ")

      assert Enum.take(reasons, -2) == ["/nonexistent/mpp is missing", "/nope is missing"]
      assert length(reasons) == if(Native.available?(), do: 2, else: 3)
    end

    test "rknn is unusable, with the reason, when the board NIF did not load" do
      System.delete_env("CAIRN_RKNN_LIBRARY")

      # CI never builds the library, so this is the branch it reaches.
      if Native.available?() do
        assert Board.preflight() == %{decoders: %{}, backends: %{}}
      else
        assert %{decoders: %{"rkmpp" => decoders}, backends: %{"rknn" => reason}} =
                 Board.preflight()

        assert decoders =~ "the board NIF did not load"
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
