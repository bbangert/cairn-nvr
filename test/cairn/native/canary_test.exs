defmodule Cairn.Native.CanaryTest do
  # The real port logic — a real OS process per test, no NIF and no Rust. What
  # `Cairn.Native.HostTest`'s StubCanary stands in for.
  use ExUnit.Case, async: true

  alias Cairn.Native.Canary
  alias Cairn.Native.Config

  @fake_detect Path.absname("test/support/fake_detect.sh")
  # Long enough that a probe ending on its own is the thing under test and not
  # the clock, short enough that a test which hangs fails inside the ExUnit one.
  @patience_ms 5_000

  setup do
    dir = Path.join(System.tmp_dir!(), "canary_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  describe "probe/2" do
    test "a ready line passes, and the probe does not outlive it", %{dir: dir} do
      config = config(dir, "ready.onnx")

      assert Canary.probe(config, binary: @fake_detect, timeout_ms: @patience_ms) == :ok
      # `Port.close/1` alone would leave this running with the model held
      assert_gone(probe_pid(config))
    end

    test "a probe that ignores SIGTERM is killed anyway", %{dir: dir} do
      config = config(dir, "deaf.onnx")

      assert Canary.probe(config, binary: @fake_detect, timeout_ms: @patience_ms) == :ok
      assert_gone(probe_pid(config))
    end

    test "a probe that never says ready is ended by the timeout, and ended", %{dir: dir} do
      config = config(dir, "hang.onnx")

      assert {:error, message} = Canary.probe(config, binary: @fake_detect, timeout_ms: 200)
      assert message =~ "within the timeout"
      assert_gone(probe_pid(config))
    end

    test "a status line that is not `ready` is not mistaken for one", %{dir: dir} do
      config = config(dir, "noise.onnx")

      assert {:error, message} =
               Canary.probe(config, binary: @fake_detect, timeout_ms: @patience_ms)

      assert message =~ "status 2"
      # what it said on the way out, in order, is the whole diagnosis
      assert message =~ ~s("state":"starting")
      assert message =~ "not ndjson at all"
    end

    test "an exit signal ends the probe now and is left for its caller", %{dir: dir} do
      config = config(dir, "hang.onnx")
      test = self()

      caller =
        spawn(fn ->
          # exactly what `Cairn.Native.Host` does, which is why the signal lands
          # in the same receive the probe is waiting in
          Process.flag(:trap_exit, true)
          send(test, :probing)
          result = Canary.probe(config, binary: @fake_detect, timeout_ms: 120_000)
          send(test, {:done, result, Process.info(self(), :messages)})
        end)

      assert_receive :probing
      os_pid = probe_pid(config)
      Process.exit(caller, :shutdown)

      assert_receive {:done, {:error, message}, {:messages, mailbox}}, @patience_ms
      assert message =~ "caller is exiting"
      # the shutdown is the caller's to act on, and it is still there to act on
      assert Enum.any?(mailbox, &match?({:EXIT, _pid, :shutdown}, &1))
      assert_gone(os_pid)
    end

    test "a caller killed outright leaves no probe behind", %{dir: dir} do
      config = config(dir, "hang.onnx")

      caller = spawn(fn -> Canary.probe(config, binary: @fake_detect, timeout_ms: 120_000) end)
      os_pid = probe_pid(config)

      # the host, killed mid-canary: nothing in the BEAM runs after this, so the
      # only thing left holding the model and the NPU is this probe
      Process.exit(caller, :kill)
      assert_gone(os_pid)
    end
  end

  defp config(dir, model) do
    {:ok, config} = Config.normalize(model: Path.join(dir, model))
    config
  end

  # The fake binary writes its own pid next to the --model path; naming the OS
  # process is the only way to prove it is gone rather than merely detached.
  defp probe_pid(config) do
    path = config.model <> ".pid"
    eventually(fn -> read_pid(path) end, "the probe never wrote #{path}")
  end

  defp read_pid(path) do
    with {:ok, data} <- File.read(path),
         {os_pid, ""} <- Integer.parse(String.trim(data)) do
      os_pid
    else
      _unwritten -> nil
    end
  end

  defp assert_gone(os_pid) do
    eventually(fn -> not alive?(os_pid) end, "the probe #{os_pid} outlived the canary")
  end

  defp alive?(os_pid) do
    {_out, status} = System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)
    status == 0
  end

  defp eventually(fun, message) do
    poll(fun, message, System.monotonic_time(:millisecond) + @patience_ms)
  end

  defp poll(fun, message, deadline) do
    case fun.() do
      result when result not in [nil, false] ->
        result

      _not_yet ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk(message)
        else
          Process.sleep(25)
          poll(fun, message, deadline)
        end
    end
  end
end
