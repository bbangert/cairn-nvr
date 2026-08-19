defmodule Cairn.Native.CanarySignalTest do
  # async: false — hides the `kill` executable by narrowing PATH, which is
  # process-global. The scenario is the device-proven one: the probe loads
  # the model and says ready, then the teardown's `System.cmd("kill", …)`
  # raises because the image ships no kill binary.
  use ExUnit.Case, async: false

  alias Cairn.Native.Canary
  alias Cairn.Native.Config

  @fake_detect Path.absname("test/support/fake_detect.sh")

  test "a teardown failure after ready keeps its own label and spares the caller" do
    dir = Path.join(System.tmp_dir!(), "canary_sig_#{System.unique_integer([:positive])}")
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)
    # The ready branch of fake_detect.sh needs exactly `sleep` from PATH.
    File.ln_s!(System.find_executable("sleep"), Path.join(bin, "sleep"))
    prior = System.get_env("PATH")
    System.put_env("PATH", bin)

    on_exit(fn ->
      System.put_env("PATH", prior)
      File.rm_rf!(dir)
    end)

    {:ok, config} = Config.normalize(model: Path.join(dir, "ready.onnx"))

    # This test process is the caller and traps nothing: surviving to make
    # the assertion is the contract — a result(), never a link exit. The
    # fake probe (a 30 s sleep) outlives the test by design: the signal
    # raised before the escalation could run, which is the leak the distinct
    # label exists to report.
    assert {:error, message} = Canary.probe(config, binary: @fake_detect, timeout_ms: 5_000)
    assert message =~ "the probe failed after starting"
    assert message =~ "enoent"
  end
end
