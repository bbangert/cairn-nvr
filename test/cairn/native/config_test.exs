defmodule Cairn.Native.ConfigTest do
  # `sample_fps` only. The rest of `normalize/1` and `to_argv/1` is covered in
  # `Cairn.NativeTest` alongside the NIF module itself.
  use ExUnit.Case, async: true

  alias Cairn.Native.Config

  describe "normalize/1 on sample_fps" do
    test "a rate the crate would refuse is a config error, not a crash" do
      # Task 3.3 makes this profile-derived rather than a literal, and the crate
      # takes it as a number: a string or a float reaches rustler's decode, which
      # raises inside `Cairn.Native.init/1` — taking the host GenServer with it —
      # where a malformed string field comes back as a refusal.
      for bad <- ["5", 5.0, nil, :fast, 0, -1, 31] do
        assert {:error, message} = Config.normalize(model: "m.onnx", sample_fps: bad)
        assert message =~ "sample_fps must be an integer in 1..30"
      end
    end

    test "the crate's own range is what passes" do
      for good <- [1, 5, 30] do
        assert {:ok, %{sample_fps: ^good}} =
                 Config.normalize(model: "m.onnx", sample_fps: good)
      end
    end
  end
end
