defmodule Cairn.FixtureBoardTest do
  # What the base does with any board, on one attached from a built board
  # directory. Excluded by default, since the directory is built outside
  # this suite (tools/ci/build-fixture-board.sh); CI's `board-loader` job
  # runs it with CAIRN_FIXTURE_BOARD_DIR set. Not async: the attached board
  # is VM-global.
  use ExUnit.Case, async: false

  import Membrane.ChildrenSpec

  alias Cairn.Board.Loader
  alias Cairn.Config
  alias Cairn.FixtureBoard.{FakeDecode, Native}
  alias Cairn.Native.Drain
  alias Cairn.Pipeline.DetectChain

  @moduletag :fixture_board
  @key {Loader, :board}

  setup_all do
    dir = System.fetch_env!("CAIRN_FIXTURE_BOARD_DIR")
    before = :persistent_term.get(@key, :unset)

    on_exit(fn ->
      if before == :unset,
        do: :persistent_term.erase(@key),
        else: :persistent_term.put(@key, before)
    end)

    :persistent_term.erase(@key)
    :ok = Loader.attach(dir)
    :ok
  end

  defp map(profile, dirs, group \\ %{"allow_experimental" => true}) do
    %{
      "data_dir" => "tmp/cfg_test",
      "profile_dirs" => dirs,
      "plugins" => %{"det" => Map.put(group, "profile", profile)}
    }
  end

  defp profile_dir(name, yaml) do
    dir = Path.join(System.tmp_dir!(), "cairn_fx_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "#{name}.yml"), yaml)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp fake(model_profile, experimental) do
    model = Path.join(System.tmp_dir!(), "cairn_fx_#{System.unique_integer([:positive])}.fake")
    File.write!(model, "")
    on_exit(fn -> File.rm(model) end)

    """
    experimental: #{experimental}
    backend: fake
    model:
      fake: #{model}
    model_profile: #{model_profile}
    """
  end

  test "the base drains the board's libraries, engines first" do
    assert Cairn.Board.module() == Cairn.FixtureBoard.Board
    assert Drain.libraries() == [Native, CairnOrt, Cairn.Native]
  end

  test "a camera on the board's decoder gets the board's step" do
    detect = [stream_params: %{min_score: %{}, motion_json: nil}, decoder: "fake"]
    spec = DetectChain.build(get_child(:tagger), %{id: "cam_a"}, detect)
    children = Map.new(spec.children, fn {name, element, _opts} -> {name, element} end)

    assert children.decoder == FakeDecode
  end

  test "a backend the board does not provide is refused by the board's name" do
    dir = profile_dir("q", "experimental: true\nbackend: qnn\nmodel:\n  qnn: m.onnx\n")
    assert {:error, errors} = Config.from_map(map("q", [dir]))

    assert Enum.any?(
             errors,
             &(&1 =~ ~s(unknown backend "qnn" — the fixture board provides fake or ort))
           )
  end

  test "the node's profiles are the base's and the board's, and no other board's" do
    assert {:ok, config, []} = Config.from_map(%{"data_dir" => "tmp/cfg_test"})
    assert Enum.sort(Map.keys(config.profiles)) == ["fixture-fake", "generic-ort"]

    assert {:error, errors} = Config.from_map(map("qcs6490-tier1", []))
    assert Enum.any?(errors, &(&1 =~ ~s(unknown profile "qcs6490-tier1")))
  end

  test "an unproven conversion needs experimental: true, and then warns its reason" do
    dir = profile_dir("v10", fake("yolov10", false))
    assert {:error, errors} = Config.from_map(map("v10", [dir]))

    assert ("profile v10: model_profile yolov10 is not a proven fake conversion: the fixture " <>
              "says so — experimental: true loads it regardless (measurements: test/fixture_board)") in errors

    dir = profile_dir("v10", fake("yolov10", true))
    assert {:ok, _config, warnings} = Config.from_map(map("v10", [dir]))
    assert Enum.any?(warnings, &(&1 =~ "which is not a proven fake conversion: the fixture"))
  end

  test "an experimental backend needs both acknowledgements (D-P10)" do
    dir = profile_dir("fx", fake("yolox", false))
    assert {:error, errors} = Config.from_map(map("fx", [dir]))
    assert Enum.any?(errors, &(&1 =~ "experimental on the fixture board"))

    dir = profile_dir("fx", fake("yolox", true))
    assert {:error, errors} = Config.from_map(map("fx", [dir], %{}))
    assert Enum.any?(errors, &(&1 =~ "set allow_experimental: true on this plugin group"))

    assert {:ok, _config, []} = Config.from_map(map("fx", [dir]))
  end
end
