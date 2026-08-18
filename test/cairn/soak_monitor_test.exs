defmodule Cairn.SoakMonitorTest do
  # async: false — flips the monitor's global enable and subscribes a
  # globally named process.
  use ExUnit.Case, async: false

  alias Cairn.SoakMonitor

  setup do
    Application.put_env(:cairn, SoakMonitor, enabled: true)
    on_exit(fn -> Application.put_env(:cairn, SoakMonitor, enabled: false) end)

    dir = Path.join(System.tmp_dir!(), "soak-monitor-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "boots, counts topic traffic, and writes samples plus a rolling report", %{dir: dir} do
    start_supervised!({SoakMonitor, dir: dir, interval_ms: 25})

    Phoenix.PubSub.broadcast(Cairn.PubSub, Cairn.Event.topic(), {:presence_started, %{}})
    Phoenix.PubSub.broadcast(Cairn.PubSub, Cairn.Event.topic(), {:presence_cleared, %{}})

    samples = Path.join(dir, "samples.jsonl")
    report = Path.join(dir, "report.md")
    wait_until(fn -> match?({:ok, _}, File.stat(report)) end)

    lines =
      samples |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

    assert [%{"boot" => true} | rest] = lines
    assert rest != []

    # The counters may land a tick after the broadcasts — wait for the sample
    # that has seen both, then check the report told the same story.
    wait_until(fn ->
      last = samples |> File.read!() |> String.split("\n", trim: true) |> List.last()
      counts = Jason.decode!(last)["counts"]
      counts["presence_started"] == 1 and counts["presence_cleared"] == 1
    end)

    assert File.read!(report) =~ "started 1 / cleared 1"
  end

  test "stays out of the tree when disabled" do
    Application.put_env(:cairn, SoakMonitor, enabled: false)
    assert :ignore = SoakMonitor.init([])
  end

  test "rotates samples.jsonl once it reaches the size bound", %{dir: dir} do
    # max_bytes: 1 — any existing file rotates on the next append, so two
    # samples are enough to observe the .1 backup without writing 10 MB.
    start_supervised!({SoakMonitor, dir: dir, interval_ms: 25, max_bytes: 1})

    wait_until(fn -> File.exists?(Path.join(dir, "samples.jsonl.1")) end)
    assert File.exists?(Path.join(dir, "samples.jsonl"))
  end

  test "host restarts count pid changes, not first sight or stability" do
    state = %{host_pid: nil, host_restarts: 0}

    pid_a = spawn(fn -> :ok end)
    pid_b = spawn(fn -> :ok end)

    # First sight adopts without counting; stability holds; a change counts.
    adopted = SoakMonitor.detect_host_restart(state, pid_a)
    assert %{host_pid: ^pid_a, host_restarts: 0} = adopted
    assert SoakMonitor.detect_host_restart(adopted, pid_a) == adopted
    assert %{host_pid: ^pid_b, host_restarts: 1} = SoakMonitor.detect_host_restart(adopted, pid_b)
  end

  defp wait_until(fun, tries \\ 200) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never became true")
      true -> Process.sleep(10) && wait_until(fun, tries - 1)
    end
  end
end
