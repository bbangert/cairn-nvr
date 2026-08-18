defmodule Cairn.SoakMonitorTest do
  # async: false — flips the monitor's global enable and subscribes a
  # globally named process.
  use ExUnit.Case, async: false

  alias Cairn.SoakMonitor

  # Ticks are driven by explicit `:sample` sends + `:sys.get_state/1` for
  # synchronization — no wall-clock polling. The huge interval keeps the
  # monitor's own timer out of the picture.
  @never :timer.hours(1)

  setup do
    Application.put_env(:cairn, SoakMonitor, enabled: true)
    on_exit(fn -> Application.put_env(:cairn, SoakMonitor, enabled: false) end)

    dir = Path.join(System.tmp_dir!(), "soak-monitor-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "boots, counts topic traffic, and writes samples plus a rolling report", %{dir: dir} do
    pid = start_supervised!({SoakMonitor, dir: dir, interval_ms: @never})

    # PubSub local dispatch delivers from this process synchronously, so both
    # broadcasts are in the monitor's mailbox before the tick that follows.
    Phoenix.PubSub.broadcast(Cairn.PubSub, Cairn.Event.topic(), {:presence_started, %{}})
    Phoenix.PubSub.broadcast(Cairn.PubSub, Cairn.Event.topic(), {:presence_cleared, %{}})
    tick(pid)

    lines =
      Path.join(dir, "samples.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert [%{"boot" => true}, sample] = lines
    assert sample["counts"] == %{"presence_started" => 1, "presence_cleared" => 1}
    assert File.read!(Path.join(dir, "report.md")) =~ "started 1 / cleared 1"
  end

  test "rotates samples.jsonl once it reaches the size bound", %{dir: dir} do
    # max_bytes: 1 — the boot record alone crosses the bound, so the first
    # tick's append rotates it out.
    pid = start_supervised!({SoakMonitor, dir: dir, interval_ms: @never, max_bytes: 1})
    tick(pid)

    assert File.exists?(Path.join(dir, "samples.jsonl.1"))
    assert File.exists?(Path.join(dir, "samples.jsonl"))
  end

  test "every monitored Host crash counts, not one per sample window", %{dir: dir} do
    pid = start_supervised!({SoakMonitor, dir: dir, interval_ms: @never})
    %{host_ref: ref} = :sys.get_state(pid)

    # Two DOWNs of the currently monitored ref = two restarts, even with no
    # sample tick in between — the sampled-pid-comparison design this
    # replaced would have collapsed them into one.
    send(pid, {:DOWN, ref, :process, self(), :killed})
    %{host_ref: ref2, host_restarts: 1} = :sys.get_state(pid)
    send(pid, {:DOWN, ref2, :process, self(), :killed})
    assert %{host_restarts: 2} = :sys.get_state(pid)

    # A stale ref (a monitor superseded by re-arming) is ignored.
    send(pid, {:DOWN, ref, :process, self(), :killed})
    assert %{host_restarts: 2} = :sys.get_state(pid)
  end

  test "stays out of the tree when disabled" do
    Application.put_env(:cairn, SoakMonitor, enabled: false)
    assert :ignore = SoakMonitor.init([])
  end

  # send + get_state: the sample is processed (files written) by the time
  # get_state returns, because both are served by the same single mailbox.
  defp tick(pid) do
    send(pid, :sample)
    :sys.get_state(pid)
  end
end
