defmodule Cairn.Native.ConfigTest do
  # The term *types* the crate decodes. The vocabulary itself — which keys there
  # are, what `to_argv/1` makes of them — is covered in `Cairn.NativeTest`
  # alongside the NIF module.
  #
  # Every case here is one rustler would raise on while decoding, which happens
  # before the guarded NIF body and so reaches the caller as a `badarg` rather
  # than as an error value. `Cairn.Native.Host` calls both of these from its
  # GenServer, so the caller is the host every camera on the node shares.
  use ExUnit.Case, async: true

  alias Cairn.Native.Config

  describe "normalize/1" do
    test "a model field whose type the crate could not decode is an error, not a crash" do
      for {config, expected} <- [
            {[model: "m.onnx", backend: nil], "backend must be a string"},
            {[model: "m.onnx", decoder: nil], "decoder must be a string"},
            {[model: "m.onnx", input_size: %{w: 640}], "input_size must be a string"},
            {[model: "m.onnx", labels: ["coco.names"]], "labels must be a string"},
            {[model: "m.onnx", allow_label_mismatch: "true"],
             "allow_label_mismatch must be true or false"},
            {[model: "m.onnx", sample_fps: "5"], "sample_fps must be an integer in 1..30"}
          ] do
        assert {:error, message} = Config.normalize(config), "#{inspect(config)} was accepted"
        assert message =~ expected
      end
    end

    test "the crate's own sample_fps range is what passes" do
      for good <- [1, 5, 30] do
        assert {:ok, %{sample_fps: ^good}} = Config.normalize(model: "m.onnx", sample_fps: good)
      end

      for bad <- [5.0, nil, :fast, 0, -1, 31] do
        assert {:error, message} = Config.normalize(model: "m.onnx", sample_fps: bad)
        assert message =~ "sample_fps must be an integer in 1..30"
      end
    end

    test "a qnn option the crate takes as a u32 is checked here" do
      for {qnn, expected} <- [
            {%{soc_model: "35"}, "qnn.soc_model must be an integer"},
            {%{htp_arch: 73.0}, "qnn.htp_arch must be an integer"},
            {%{vtcm_mb: -1}, "qnn.vtcm_mb must be an integer"},
            {%{library: ["libQnnHtp.so"]}, "qnn.library must be a string"},
            {:none, "qnn must be a map"}
          ] do
        assert {:error, message} = Config.normalize(model: "m.onnx", qnn: qnn),
               "#{inspect(qnn)} was accepted"

        assert message =~ expected
      end
    end

    test "nil qnn options are no qnn options, which is what the defaults already are" do
      assert Config.normalize(model: "m.onnx", qnn: nil) == Config.normalize(model: "m.onnx")
    end

    test "a config that is not a map or keyword list is refused rather than raised on" do
      assert {:error, message} = Config.normalize("--backend qnn")
      assert message =~ "must be a map or keyword list"
    end
  end

  describe "stream_params/1" do
    test "a scene knob whose type the crate could not decode is an error, not a crash" do
      for {params, expected} <- [
            {[min_score: %{"person" => "0.8"}], "min_score must be a map of"},
            {[min_score: %{person: 0.8}], "min_score must be a map of"},
            {[min_score: nil], "min_score must be a map of"},
            {[motion_json: %{}], "motion_json must be a string"},
            {[track_floor_json: %{}], "track_floor_json must be a string"},
            {[stream_epoch: %{}], "stream_epoch must be a string"}
          ] do
        assert {:error, message} = Config.stream_params(params), "#{inspect(params)} was accepted"
        assert message =~ expected
      end

      assert {:error, message} = Config.stream_params("min_score")
      assert message =~ "must be a map or keyword list"
    end

    test "either spelling of a number is a floor, and reaches the crate as written" do
      assert {:ok, params} = Config.stream_params(min_score: %{"person" => 1, "car" => 0.4})
      assert params.min_score == %{"person" => 1, "car" => 0.4}
    end

    test "the defaults are every key the crate's decode requires" do
      assert Config.stream_params(%{}) ==
               {:ok,
                %{min_score: %{}, motion_json: nil, track_floor_json: nil, stream_epoch: nil}}
    end
  end
end
