defmodule Cairn.Native.HealthTest do
  # `Cairn.NativeStub` and `Cairn.CanaryStub` are driven through one global
  # control map.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Cairn.CanaryStub
  alias Cairn.Native.Health
  alias Cairn.Native.Host
  alias Cairn.NativeStub

  # every escalation here logs at :error on purpose
  @moduletag :capture_log

  @control NativeStub.control()

  setup do
    :persistent_term.put(@control, %{test: self()})
    on_exit(fn -> :persistent_term.erase(@control) end)
    %{id: "nh_#{System.unique_integer([:positive])}"}
  end

  defp control(attrs) do
    :persistent_term.put(@control, Map.merge(:persistent_term.get(@control, %{}), attrs))
  end

  # Unlinked, so a test can kill it the way a pipeline rebuild kills a camera, and
  # killed at exit so that no call a test left hanging outlives it.
  defp spawn_pusher(host, id) do
    pusher = spawn(fn -> NativeStub.host_push(host, id) end)
    on_exit(fn -> Process.exit(pusher, :kill) end)
    pusher
  end

  defp kill(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
  end

  defp eventually(fun, attempts \\ 200) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("the condition never held")
      true -> Process.sleep(5) && eventually(fun, attempts - 1)
    end
  end

  # The monitor is a sibling of the host, not a child: the two are started
  # separately here because that is how the supervisor starts them.
  defp start_host(opts) do
    name = :"host_#{System.unique_integer([:positive])}"
    {health, opts} = Keyword.pop(opts, :health, [])

    defaults = [
      name: name,
      native_module: NativeStub,
      ort_module: Cairn.CairnOrtStub,
      canary_module: CanaryStub,
      config: %{model: "m.onnx", backend: "qnn"}
    ]

    start_supervised!({Host, Keyword.merge(defaults, opts)}, id: name)
    start_supervised!({Health, Keyword.put(health, :host, name)}, id: Health.name(name))

    name
  end

  describe "health check" do
    defp health(extra \\ []) do
      # `stall_ms: 0` leaves a hang to the window rule alone: the bound has a test of
      # its own
      [
        health:
          Keyword.merge(
            [cpu_baseline_ms: 45.0, min_ratio: 3.0, min_samples: 3, stall_ms: 0],
            extra
          )
      ]
    end

    defp push(host, id, count) do
      Enum.each(1..count, fn n -> NativeStub.host_push(host, id, n) end)
    end

    defp slow_push(millis) do
      fn _stream, _payload, _meta, _time_base ->
        Process.sleep(millis)
        {:ok, {[NativeStub.frame()], []}}
      end
    end

    # One model pass every `gated + 1` calls, the rest replayed by the gate: the
    # default sampler's shape on a stream whose frame rate is well above it.
    defp gated_then_pass(gated, millis) do
      calls = :counters.new(1, [])

      fn _stream, _payload, _meta, _time_base ->
        n = :counters.get(calls, 1)
        :counters.add(calls, 1, 1)

        if rem(n, gated + 1) == gated do
          Process.sleep(millis)
          {:ok, {[NativeStub.frame()], []}}
        else
          {:ok, {[NativeStub.frame(false)], []}}
        end
      end
    end

    test "a call the model never ran on is not an inference", %{id: id} do
      host = start_host(health())
      {:ok, _epoch} = Host.open_stream(host, id, %{})

      # the sampler not due: the call decoded and returned no frame at all
      control(%{push_frame: {:ok, {[], []}}})
      push(host, id, 10)
      # the motion gate: a frame, re-reporting the last real pass's objects
      control(%{push_frame: {:ok, {[NativeStub.frame(false)], []}}})
      push(host, id, 10)

      # 20 fast calls and not one model pass is no evidence about the
      # accelerator, and must not read as health
      assert Host.check_health(host) == :idle

      status = Host.status(host)
      assert status.inferences == 0
      assert status.p50_ms == nil
      assert status.stream_health == %{}
    end

    test "a stream sampled well under its frame rate reports the model's rate", %{id: id} do
      # The membrane branch's real shape: the sink calls once per access unit and
      # the crate's rate gate admits a fifth of them. `stream_fps` and the
      # throughput arithmetic must both count the passes and not the calls.
      control(%{push_frame: gated_then_pass(4, 1)})
      host = start_host(health())
      {:ok, _epoch} = Host.open_stream(host, id, %{})

      Host.check_health(host)
      started = System.monotonic_time(:millisecond)
      push(host, id, 100)
      Process.sleep(100)

      # 20 passes at ~1 ms against a 45 ms baseline: fast work, not queued work
      assert Host.check_health(host) == :healthy
      elapsed = System.monotonic_time(:millisecond) - started

      status = Host.status(host)
      assert status.inferences == 20
      # …and the published rate is those 20 over the window, nowhere near the 100
      assert status.stream_fps[id] * elapsed / 1000 <= 25
      assert status.stream_fps[id] > 0
    end

    test "a gate skipping every frame is idle, and never becomes a wedge", %{id: id} do
      control(%{push_frame: {:ok, {[NativeStub.frame(false)], []}}})
      host = start_host(health())
      {:ok, _epoch} = Host.open_stream(host, id, %{})

      push(host, id, 20)
      assert Host.check_health(host) == :idle

      # a second window of the same: nothing outstanding, so nothing to escalate
      push(host, id, 20)
      log = capture_log(fn -> assert Host.check_health(host) == :idle end)
      refute log =~ "FAILED"
    end

    test "no-model calls cannot vouch for a model pass at CPU speed", %{id: id} do
      # The pass itself is 8 ms against a 15 ms baseline — the D-P5 signature of
      # an HTP that is not executing — in traffic whose p50 is 0 because nine
      # calls in ten ran no model at all.
      control(%{push_frame: gated_then_pass(9, 8)})
      host = start_host(health(cpu_baseline_ms: 15.0))
      {:ok, _epoch} = Host.open_stream(host, id, %{})

      push(host, id, 40)

      log = capture_log(fn -> assert Host.check_health(host) == :wedged end)
      assert log =~ "NPU health check FAILED"
      assert Host.status(host).p50_ms >= 8.0
      assert Host.status(host).inferences == 4
    end

    test "another camera's no-model traffic does not hide a hung call", %{id: id} do
      gated = id <> "_gated"
      caller = self()

      control(%{
        push_frame: fn _stream, _payload, _meta, _time_base ->
          send(caller, :entered)
          Process.sleep(:infinity)
        end
      })

      host = start_host(health())
      {:ok, _epoch} = Host.open_stream(host, id, %{})
      {:ok, _epoch} = Host.open_stream(host, gated, %{})
      spawn_pusher(host, id)
      assert_receive :entered, 1_000

      assert Host.check_health(host) == :idle

      # Calls that ran no model are not the engine retiring work, so they cannot
      # stand in for the completions this window has none of.
      control(%{push_frame: {:ok, {[NativeStub.frame(false)], []}}})
      push(host, gated, 10)

      assert capture_log(fn -> assert Host.check_health(host) == :wedged end) =~ "FAILED"
    end

    test "no traffic at all is idle, not healthy", %{id: id} do
      host = start_host(health())
      {:ok, _epoch} = Host.open_stream(host, id, %{})

      assert Host.check_health(host) == :idle
      assert Host.status(host).health == :idle
    end

    test "inference well under the CPU baseline is healthy", %{id: id} do
      host = start_host(health())
      {:ok, _epoch} = Host.open_stream(host, id, %{})

      push(host, id, 10)
      assert Host.check_health(host) == :healthy

      status = Host.status(host)
      assert status.inferences == 10
      assert status.p50_ms < 45.0 / 3.0
      assert status.stream_health == %{id => :ok}
    end

    test "latency collapsed to CPU numbers is a wedge, and says so once", %{id: id} do
      # 8 ms against a 15 ms baseline: the call still answers, it is just not 3×
      # faster than the CPU — the D-P5 signature of an HTP that is not executing.
      # One caller, so throughput cannot vouch for it either.
      control(%{push_frame: slow_push(8)})
      host = start_host(health(cpu_baseline_ms: 15.0))
      {:ok, _epoch} = Host.open_stream(host, id, %{})

      push(host, id, 4)

      log = capture_log(fn -> assert Host.check_health(host) == :wedged end)
      assert log =~ "NPU health check FAILED"
      assert log =~ "will not restart itself"

      # an operator alert, not a restart loop, and not one line per window
      push(host, id, 4)
      assert capture_log(fn -> assert Host.check_health(host) == :wedged end) == ""
      assert Process.alive?(Process.whereis(host))
    end

    test "the same latency at accelerator-rate throughput is saturation", %{id: id} do
      # Four cameras each blocked 8 ms — the same p50 that read as a wedge above
      # — but the session is retiring work far faster than any CPU could, which
      # is what queueing looks like and a wedge cannot fake.
      control(%{push_frame: slow_push(8)})
      host = start_host(health(cpu_baseline_ms: 15.0))
      ids = for n <- 1..4, do: "#{id}_#{n}"
      Enum.each(ids, &Host.open_stream(host, &1, %{}))

      # start the window here, so it measures the burst and not the setup
      Host.check_health(host)

      ids
      |> Enum.map(fn camera -> Task.async(fn -> push(host, camera, 10) end) end)
      |> Task.await_many(10_000)

      # saturation is a load problem, not a fault: it must not page
      assert capture_log(fn -> assert Host.check_health(host) == :saturated end) == ""
      assert Host.status(host).stream_health == Map.new(ids, &{&1, :slow})
    end

    test "a stream's error volume cannot vouch for throughput", %{id: id} do
      slow = id <> "_slow"
      erroring = id <> "_err"

      control(%{
        push_frame: fn
          {:stream, ^slow}, _payload, _meta, _time_base ->
            Process.sleep(8)
            {:ok, {[NativeStub.frame()], []}}

          _stream, _payload, _meta, _time_base ->
            {:error, {:infer, "the model pass failed"}}
        end
      })

      host = start_host(health(cpu_baseline_ms: 10.0))
      {:ok, _epoch} = Host.open_stream(host, slow, %{})
      {:ok, _epoch} = Host.open_stream(host, erroring, %{})

      # start the window here, so it measures the burst and not the setup
      Host.check_health(host)

      # 8 ms a pass against a 10 ms baseline is under the D-P5 floor, and one
      # serial caller sleeping 8 ms cannot exceed 125 passes a second against a
      # 270 floor however many it makes. The 500 failures return at no cost at
      # all, so their volume alone clears it many times over.
      push(host, slow, 4)
      push(host, erroring, 500)

      log = capture_log(fn -> assert Host.check_health(host) == :wedged end)
      assert log =~ "NPU health check FAILED"

      status = Host.status(host)
      assert status.stream_health == %{slow => :slow, erroring => :failing}
      assert status.inferences == 4
    end

    test "one stream failing is that stream, not the accelerator", %{id: id} do
      healthy = id <> "_ok"
      host = start_host(health())
      {:ok, _epoch} = Host.open_stream(host, id, %{})
      {:ok, _epoch} = Host.open_stream(host, healthy, %{})

      push(host, healthy, 5)
      control(%{push_frame: {:error, {:infer, "the model pass failed"}}})
      push(host, id, 5)

      assert capture_log(fn -> assert Host.check_health(host) == :healthy end) == ""
      assert Host.status(host).stream_health == %{id => :failing, healthy => :ok}
    end

    test "a stream too quiet to judge is not evidence for the accelerator", %{id: id} do
      quiet = id <> "_quiet"
      # A baseline this small puts accelerator-rate throughput out of reach, so
      # what the window says is decided by the classifications alone and not by
      # how fast the test's own pushes happened to run.
      host = start_host(health(min_samples: 10, cpu_baseline_ms: 0.001))
      {:ok, _epoch} = Host.open_stream(host, id, %{})
      {:ok, _epoch} = Host.open_stream(host, quiet, %{})

      control(%{push_frame: {:error, {:infer, "the model pass failed"}}})
      push(host, id, 5)
      control(%{push_frame: nil})
      push(host, quiet, 3)

      # one camera failing and one with too few completions to have a p50 is not
      # "every stream with traffic is failing"
      assert capture_log(fn -> assert Host.check_health(host) == :unknown end) == ""
      assert Host.status(host).stream_health == %{id => :failing, quiet => :unknown}
    end

    test "every stream failing at once is the accelerator", %{id: id} do
      other = id <> "_b"
      control(%{push_frame: {:error, {:infer, "the model pass failed"}}})
      host = start_host(health())
      {:ok, _epoch} = Host.open_stream(host, id, %{})
      {:ok, _epoch} = Host.open_stream(host, other, %{})

      push(host, id, 5)
      push(host, other, 5)

      assert capture_log(fn -> assert Host.check_health(host) == :wedged end) =~ "FAILED"
    end

    test "an engine retiring nothing but errors is not silence", %{id: id} do
      control(%{push_frame: {:error, {:infer, "the model pass failed"}}})
      host = start_host(health())
      {:ok, _epoch} = Host.open_stream(host, id, %{})

      push(host, id, 20)

      # Nothing was retired — the count the throughput arithmetic runs on is 0 —
      # and the window is still not silent, which is the only reason this reaches
      # a cross-stream verdict at all rather than `:idle`'s no opinion.
      log = capture_log(fn -> assert Host.check_health(host) == :wedged end)
      assert log =~ "NPU health check FAILED"
      assert Host.status(host).inferences == 0
      assert Host.status(host).stream_health == %{id => :failing}
    end

    test "calls that go in and never come back are a wedge, not silence", %{id: id} do
      caller = self()

      control(%{
        push_frame: fn _stream, _payload, _meta, _time_base ->
          send(caller, :entered)
          Process.sleep(:infinity)
        end
      })

      host = start_host(health())
      {:ok, _epoch} = Host.open_stream(host, id, %{})
      spawn_pusher(host, id)
      assert_receive :entered, 1_000

      # the window the call was submitted in cannot tell a hang from a window
      # that merely ended mid-call; the next one, with nothing new submitted and
      # the call still outstanding, can
      assert Host.check_health(host) == :idle
      assert capture_log(fn -> assert Host.check_health(host) == :wedged end) =~ "FAILED"
    end

    # What a hung `push_frame/5` is inside the NIF: it holds its stream's lock, so
    # both the call and a close of that stream return only when `call` is
    # released, and killing the caller releases neither — the native call runs on
    # without it.
    defp native_call do
      call = spawn(fn -> receive(do: (:release -> :ok)) end)
      on_exit(fn -> Process.exit(call, :kill) end)
      call
    end

    defp until_returned(call) do
      ref = Process.monitor(call)
      receive(do: ({:DOWN, ^ref, :process, _pid, _reason} -> :ok))
    end

    # The cameras in `hung` hang on `call`; every other stream gets the stub's
    # instant pass, which is what the engine's remaining model slots look like.
    defp hang(hung, call) do
      caller = self()

      control(%{
        push_frame: fn {:stream, id}, _payload, _meta, _time_base ->
          if id in hung do
            send(caller, {:entered, id})
            until_returned(call)
          end

          {:ok, {[NativeStub.frame()], []}}
        end,
        close_stream: fn {:stream, id} ->
          if id in hung, do: until_returned(call)
          {:ok, true}
        end
      })
    end

    defp hung_beside_traffic(id, opts \\ health()) do
      busy = id <> "_busy"
      call = native_call()
      hang([id], call)
      host = start_host(opts)
      {:ok, _epoch} = Host.open_stream(host, id, %{})
      {:ok, _epoch} = Host.open_stream(host, busy, %{})
      pusher = spawn_pusher(host, id)
      assert_receive {:entered, ^id}, 1_000
      {host, busy, pusher, call}
    end

    # What `Cairn.PipelineOwner`'s stall rebuild does to a camera whose detect
    # branch went quiet: its processes die, the caller among them, and the
    # element's resource guard closes its stream.
    defp rebuild(host, id, pusher) do
      kill(pusher)
      :ok = Host.close_stream(host, id)
      assert_receive {:close_stream, {:stream, ^id}}
    end

    test "a hung call is a wedge while other streams still retire work", %{id: id} do
      {host, busy, _pusher, _call} = hung_beside_traffic(id)
      # the window the call went in during cannot call it a hang yet
      assert Host.check_health(host) == :idle

      push(host, busy, 10)

      assert capture_log(fn -> assert Host.check_health(host) == :wedged end) =~ "FAILED"
      assert Host.status(host).stream_health == %{busy => :ok}
      assert Host.status(host).stalled == [id]
    end

    test "a call that went in during the window is not a hang", %{id: id} do
      busy = id <> "_busy"
      hang([id], native_call())
      host = start_host(health())
      {:ok, _epoch} = Host.open_stream(host, id, %{})
      {:ok, _epoch} = Host.open_stream(host, busy, %{})

      Host.check_health(host)
      spawn_pusher(host, id)
      assert_receive {:entered, ^id}, 1_000
      push(host, busy, 10)

      assert capture_log(fn -> assert Host.check_health(host) == :healthy end) == ""
    end

    test "a call in flight across two back-to-back checks is not a hang until the bound",
         %{id: id} do
      {host, busy, _pusher, _call} = hung_beside_traffic(id, health(stall_ms: 500))
      assert Host.check_health(host) == :idle

      # An on-demand check right after another opens a window of a few
      # milliseconds; the call predates it, and is no older than that.
      push(host, busy, 10)
      assert capture_log(fn -> assert Host.check_health(host) == :healthy end) == ""

      Process.sleep(600)
      push(host, busy, 10)
      assert capture_log(fn -> assert Host.check_health(host) == :wedged end) =~ "FAILED"
    end

    test "a stalled row whose caller died does not outvote other traffic", %{id: id} do
      {host, busy, pusher, _call} = hung_beside_traffic(id)
      assert Host.check_health(host) == :idle

      kill(pusher)
      push(host, busy, 10)

      assert capture_log(fn -> assert Host.check_health(host) == :healthy end) == ""
    end

    test "a hung call's alert names the camera, not the D-P5 floor", %{id: id} do
      {host, busy, _pusher, _call} = hung_beside_traffic(id)
      assert Host.check_health(host) == :idle
      push(host, busy, 10)

      log = capture_log(fn -> assert Host.check_health(host) == :wedged end)
      assert log =~ "push_frame/5 call for #{id} has been inside the NIF for"
      assert log =~ "other streams still retired 10 passes"
      assert log =~ "will not restart itself"
      refute log =~ "every stream with traffic"
      refute log =~ busy
    end

    test "a hung call with no other traffic says the engine retired nothing", %{id: id} do
      hang([id], native_call())
      host = start_host(health())
      {:ok, _epoch} = Host.open_stream(host, id, %{})
      spawn_pusher(host, id)
      assert_receive {:entered, ^id}, 1_000
      assert Host.check_health(host) == :idle

      log = capture_log(fn -> assert Host.check_health(host) == :wedged end)
      assert log =~ "push_frame/5 call for #{id} has been inside the NIF"
      assert log =~ "and the engine retired nothing in this window"
    end

    test "a hung call alerts once, however many windows it stays hung", %{id: id} do
      {host, busy, _pusher, _call} = hung_beside_traffic(id)
      assert Host.check_health(host) == :idle

      log =
        capture_log(fn ->
          for _window <- 1..3 do
            push(host, busy, 10)
            assert Host.check_health(host) == :wedged
          end
        end)

      assert length(String.split(log, "FAILED")) == 2
      refute log =~ "recovered"
    end

    test "two hung calls are one alert naming both cameras", %{id: id} do
      a = id <> "_a"
      b = id <> "_b"
      busy = id <> "_busy"
      hang([a, b], native_call())
      host = start_host(health())
      Enum.each([a, b, busy], &({:ok, _epoch} = Host.open_stream(host, &1, %{})))
      spawn_pusher(host, b)
      spawn_pusher(host, a)
      assert_receive {:entered, ^a}, 1_000
      assert_receive {:entered, ^b}, 1_000
      assert Host.check_health(host) == :idle

      push(host, busy, 10)
      log = capture_log(fn -> assert Host.check_health(host) == :wedged end)
      assert log =~ "push_frame/5 calls for #{a}, #{b} have been inside the NIF"
      assert length(String.split(log, "FAILED")) == 2
      assert Host.status(host).stalled == [a, b]
    end

    # The baseline is nil, so the ratio rules would say :not_applicable — but a
    # call that does not return is a hung engine on any backend.
    test "a hung call is a wedge on a CPU backend too", %{id: id} do
      opts = [config: %{model: "m.onnx", backend: "ort"}, health: [min_samples: 3, stall_ms: 0]]
      {host, busy, _pusher, _call} = hung_beside_traffic(id, opts)
      assert Host.check_health(host) == :idle

      push(host, busy, 10)
      assert capture_log(fn -> assert Host.check_health(host) == :wedged end) =~ "FAILED"
      assert Host.status(host).cpu_baseline_ms == nil
    end

    test "a hung call stays a wedge after the stall rebuild kills its caller", %{id: id} do
      {host, busy, pusher, _call} = hung_beside_traffic(id)
      assert Host.check_health(host) == :idle
      push(host, busy, 10)
      assert capture_log(fn -> assert Host.check_health(host) == :wedged end) =~ "FAILED"

      # The caller is gone and its row reaped, but the close waits on the same
      # call: the hang has not ended, and neither a new alert nor a recovery is
      # true.
      rebuild(host, id, pusher)

      log =
        capture_log(fn ->
          for _window <- 1..2 do
            push(host, busy, 10)
            assert Host.check_health(host) == :wedged
          end
        end)

      assert log == ""
      assert Host.status(host).stalled == [id]
      assert Host.status(host).closing == [id]
    end

    test "a close younger than the bound keeps a diagnosed hang a wedge", %{id: id} do
      {host, busy, pusher, _call} = hung_beside_traffic(id, health(stall_ms: 300))
      assert Host.check_health(host) == :idle
      Process.sleep(350)
      push(host, busy, 10)
      assert capture_log(fn -> assert Host.check_health(host) == :wedged end) =~ "FAILED"

      # the close starts now, and is nowhere near the bound at the next check
      rebuild(host, id, pusher)
      push(host, busy, 10)

      assert capture_log(fn -> assert Host.check_health(host) == :wedged end) == ""
      assert Host.status(host).stalled == [id]
    end

    test "a check between the caller's death and its stream's close is no recovery",
         %{id: id} do
      {host, busy, pusher, _call} = hung_beside_traffic(id, health(stall_ms: 300))
      assert Host.check_health(host) == :idle
      Process.sleep(350)
      push(host, busy, 10)
      assert capture_log(fn -> assert Host.check_health(host) == :wedged end) =~ "FAILED"

      kill(pusher)

      # the row is reaped by the first of these; the open is what the second has
      log =
        capture_log(fn ->
          for _window <- 1..2 do
            push(host, busy, 10)
            assert Host.check_health(host) == :wedged
          end
        end)

      assert log == ""
      assert Host.status(host).stalled == [id]

      :ok = Host.close_stream(host, id)
      assert_receive {:close_stream, {:stream, ^id}}
      push(host, busy, 10)
      assert capture_log(fn -> assert Host.check_health(host) == :wedged end) == ""
    end

    test "a pass retired on a camera whose caller died ends its hang", %{id: id} do
      {host, busy, pusher, call} = hung_beside_traffic(id, health(stall_ms: 300))
      assert Host.check_health(host) == :idle
      Process.sleep(350)
      push(host, busy, 10)
      assert capture_log(fn -> assert Host.check_health(host) == :wedged end) =~ "FAILED"

      kill(pusher)
      push(host, busy, 10)
      assert capture_log(fn -> assert Host.check_health(host) == :wedged end) == ""

      # never closed, and the same open carries passes again, as after the call
      # came back
      hang([], call)
      push(host, id, 10)
      assert capture_log(fn -> assert Host.check_health(host) == :healthy end) =~ "recovered"
      assert Host.status(host).stalled == []
    end

    test "a probe that times out does not forget a diagnosed hang", %{id: id} do
      opts = health(stall_ms: 300, probe_timeout_ms: 50)
      {host, busy, pusher, _call} = hung_beside_traffic(id, opts)
      assert Host.check_health(host) == :idle
      Process.sleep(350)
      push(host, busy, 10)
      assert capture_log(fn -> assert Host.check_health(host) == :wedged end) =~ "FAILED"
      rebuild(host, id, pusher)

      # the Host inside a native call of its own for one cycle: no reply, so no closes
      caller = self()

      control(%{
        open_stream: fn _engine, _camera_id, _params ->
          send(caller, {:opening, self()})
          receive(do: (:release -> {:ok, {:stream, :late}}))
        end
      })

      spawn(fn -> Host.open_stream(host, id <> "_late", %{}) end)
      assert_receive {:opening, blocked}
      on_exit(fn -> send(blocked, :release) end)
      assert capture_log(fn -> assert Host.check_health(host) == :wedged end) == ""
      send(blocked, :release)

      # the close is still younger than the bound when the Host answers again
      push(host, busy, 10)
      assert capture_log(fn -> assert Host.check_health(host) == :wedged end) == ""
      assert Host.status(host).stalled == [id]
    end

    test "an outstanding close says what it is evidence of", %{id: id} do
      {host, busy, pusher, _call} = hung_beside_traffic(id)
      rebuild(host, id, pusher)
      push(host, busy, 10)

      log = capture_log(fn -> assert Host.check_health(host) == :wedged end)
      assert log =~ "the native close of #{id} has not landed in"
      assert log =~ "so a call into the engine on that stream has not returned"
      assert log =~ "other streams still retired 10 passes"
      refute log =~ "push_frame/5 call"
    end

    test "a camera whose call and close are both outstanding is named once", %{id: id} do
      {host, _busy, _pusher, _call} = hung_beside_traffic(id, health(stall_ms: 300))
      # closed with its caller still alive and inside the call
      :ok = Host.close_stream(host, id)
      assert_receive {:close_stream, {:stream, ^id}}
      assert Host.check_health(host) == :idle

      # both past the bound in the same window
      Process.sleep(350)

      log = capture_log(fn -> assert Host.check_health(host) == :wedged end)
      assert log =~ "push_frame/5 call for #{id}"
      refute log =~ "native close"
    end

    test "the hung call returning lands its close and recovers once", %{id: id} do
      {host, busy, pusher, call} = hung_beside_traffic(id)
      assert Host.check_health(host) == :idle
      push(host, busy, 10)
      assert capture_log(fn -> assert Host.check_health(host) == :wedged end) =~ "FAILED"
      rebuild(host, id, pusher)

      send(call, :release)
      eventually(fn -> Host.status(host).closing == [] end)

      log =
        capture_log(fn ->
          for _window <- 1..2 do
            push(host, busy, 10)
            assert Host.check_health(host) == :healthy
          end
        end)

      assert length(String.split(log, "recovered")) == 2
      assert Host.status(host).stalled == []
    end

    test "a caller killed mid-call is not a wedge, and does not become one", %{id: id} do
      caller = self()

      control(%{
        push_frame: fn _stream, _payload, _meta, _time_base ->
          send(caller, :entered)
          Process.sleep(:infinity)
        end
      })

      host = start_host(health())
      {:ok, _epoch} = Host.open_stream(host, id, %{})
      pusher = spawn_pusher(host, id)
      assert_receive :entered, 1_000

      # the shape the wedge above is read off — submitted, never completed —
      # produced by a camera process dying rather than by the NIF hanging
      ref = Process.monitor(pusher)
      Process.exit(pusher, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pusher, :killed}

      assert Host.check_health(host) == :idle
      log = capture_log(fn -> assert Host.check_health(host) == :idle end)
      refute log =~ "FAILED"
    end

    # Nothing in `lib/` supplied `cpu_baseline_ms`, so every verdict a running
    # node could reach was `:not_applicable` and the four-way discrimination
    # below never ran. The engine measures its own now.
    test "an accelerator calibrates its CPU baseline at engine init", %{id: id} do
      host =
        start_host(
          config: %{model: "test/support/fixtures/models/stub.onnx", backend: "qnn"},
          health: [min_samples: 3]
        )

      {:ok, _epoch} = Host.open_stream(host, id, %{})

      assert_receive {:cpu_baseline,
                      %{model: "test/support/fixtures/models/stub.onnx", backend: "qnn"}, passes,
                      _opts}

      assert passes in 1..64

      # the measurement is asynchronous; the verdict below needs it landed
      await_baseline(host)
      push(host, id, 10)

      assert Host.check_health(host) == :healthy
      assert Host.status(host).cpu_baseline_ms == 45.0
    end

    # Event-driven, never timed: the task's own exit is the signal, and the
    # `:sys.get_state/1` round-trips after it are real synchronizations with
    # the host's queue.
    defp await_baseline(host) do
      case :sys.get_state(host).baseline_task do
        nil ->
          :ok

        %{task: %Task{pid: pid}} ->
          ref = Process.monitor(pid)

          receive do
            {:DOWN, ^ref, :process, _pid, _reason} -> :ok
          after
            5_000 -> flunk("the baseline task never finished")
          end

          drain_baseline(host, 100)
      end
    end

    defp drain_baseline(_host, 0), do: flunk("the host never consumed the baseline result")

    defp drain_baseline(host, attempts) do
      unless :sys.get_state(host).baseline_task == nil do
        drain_baseline(host, attempts - 1)
      end

      :ok
    end

    test "a CPU backend measures nothing: it is the baseline", %{id: id} do
      host = start_host(config: %{model: "m.onnx", backend: "ort"}, health: [min_samples: 3])
      {:ok, _epoch} = Host.open_stream(host, id, %{})

      push(host, id, 5)

      # no second model load paid, and no ratio to judge by
      refute_received {:cpu_baseline_ms, _config, _passes}
      assert Host.check_health(host) == :not_applicable
      assert Host.status(host).cpu_baseline_ms == nil
    end

    test "a baseline that cannot be measured costs the ratio, not the engine", %{id: id} do
      control(%{cpu_baseline_ms: {:error, {:model_load, "the CPU EP would not take the QDQ"}}})
      host = start_host(health: [min_samples: 3])
      {:ok, _epoch} = Host.open_stream(host, id, %{})

      push(host, id, 10)

      assert Host.status(host).engine == :ready
      assert Host.status(host).cpu_baseline_ms == nil
      assert Host.check_health(host) == :not_applicable
    end

    test "a measurement that does not come back does not hold the boot", %{id: id} do
      control(%{cpu_baseline_ms: fn _config, _passes -> Process.sleep(:infinity) end})

      host =
        start_host(baseline_timeout_ms: 50, health: [min_samples: 3])

      {:ok, _epoch} = Host.open_stream(host, id, %{})
      push(host, id, 10)

      assert Host.status(host).engine == :ready
      assert Host.status(host).cpu_baseline_ms == nil
      assert Host.check_health(host) == :not_applicable
    end

    test "a host with no engine has no opinion" do
      host = start_host(config: nil)
      assert Host.check_health(host) == :unknown
    end
  end

  describe "the probe" do
    test "a verdict is reached while the host is blocked inside a native call", %{id: id} do
      caller = self()

      control(%{
        open_stream: fn _engine, _camera_id, _params ->
          send(caller, {:opening, self()})

          receive do
            :release -> {:ok, {:stream, :late}}
          end
        end
      })

      host = start_host(health(probe_timeout_ms: 50))
      spawn(fn -> Host.open_stream(host, id, %{}) end)
      assert_receive {:opening, blocked}
      on_exit(fn -> send(blocked, :release) end)
      # the host's own process, inside the NIF: every call to it now queues behind
      # this one, which is where the health check used to be
      assert blocked == Process.whereis(host)

      log = capture_log(fn -> assert Host.check_health(host) == :wedged end)
      assert log =~ "NPU health check FAILED"
      assert log =~ "did not answer"

      send(blocked, :release)
    end

    test "the deadline alone is the verdict, with no window evidence at all" do
      name = :"deaf_host_#{System.unique_integer([:positive])}"
      deaf = spawn(fn -> Process.sleep(:infinity) end)
      Process.register(deaf, name)
      on_exit(fn -> Process.exit(deaf, :kill) end)

      start_supervised!({Health, host: name, probe_timeout_ms: 25}, id: Health.name(name))

      # no streams, no traffic and nothing in flight: every other line of evidence
      # says :idle, and there is not even a table to read it out of
      log = capture_log(fn -> assert Health.check(Health.name(name)) == :wedged end)
      assert log =~ "did not answer a 25 ms probe"
    end

    test "a sink that stopped re-demanding is told from a camera with nothing to send",
         %{id: id} do
      caller = self()
      host = start_host(health())
      {:ok, _epoch} = Host.open_stream(host, id, %{})

      # a camera whose media stopped: silent, with nothing outstanding
      assert Host.check_health(host) == :idle

      control(%{
        push_frame: fn _stream, _payload, _meta, _time_base ->
          send(caller, :entered)
          Process.sleep(:infinity)
        end
      })

      spawn_pusher(host, id)
      assert_receive :entered, 1_000

      # A wedged push is as silent as that: no error, no crash, no counter moving,
      # and the host itself answers its probe throughout. The outstanding call is
      # the whole difference between the two.
      assert Host.check_health(host) == :idle
      assert capture_log(fn -> assert Host.check_health(host) == :wedged end) =~ "FAILED"
      assert Host.status(host).engine == :ready
    end
  end
end
