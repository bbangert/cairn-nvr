defmodule Cairn.Native.HostTest do
  # `Cairn.NativeStub` and `Cairn.CanaryStub` are driven through one global
  # control map, and the epoch assertions ride the application-wide PubSub.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Cairn.CanaryStub
  alias Cairn.Native.Host
  alias Cairn.NativeStub
  alias Cairn.StreamEpochs

  # every refusal path here logs at :error on purpose
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

  defp start_host(opts \\ []) do
    name = :"host_#{System.unique_integer([:positive])}"

    defaults = [
      name: name,
      native_module: NativeStub,
      canary_module: CanaryStub,
      config: %{model: "m.onnx", backend: "qnn"}
    ]

    start_supervised!({Host, Keyword.merge(defaults, opts)}, id: name)

    name
  end

  describe "engine lifecycle" do
    test "the canary runs before the NIF is allowed to load the model" do
      host = start_host()

      assert_receive {:canary, %{model: "m.onnx"}, _opts}
      assert_receive {:init, %{model: "m.onnx", backend: "qnn"}}

      status = Host.status(host)
      assert status.engine == :ready
      assert status.canary == :passed
      assert status.model == "m.onnx"
    end

    test "a failed canary refuses the model and never calls init/1", %{id: id} do
      control(%{canary: {:error, "the HTP would not compile the graph"}})

      log = capture_log(fn -> Host.status(start_host()) end)

      assert_receive {:canary, _config, _opts}
      refute_received {:init, _config}
      assert log =~ "canary refused"
      assert log =~ "was NOT loaded in this VM"

      host = start_host()
      status = Host.status(host)
      assert {:canary_failed, _message} = status.engine
      assert {:failed, _message} = status.canary
      assert {:error, {:canary_failed, _message}} = Host.open_stream(host, id, %{})
    end

    test "a skipped canary still loads the model" do
      control(%{canary: {:skipped, :no_binary}})
      host = start_host()

      assert_receive {:init, _config}
      assert Host.status(host).canary == {:skipped, :no_binary}
      assert Host.status(host).engine == :ready
    end

    test "no model configured leaves the host inert and up", %{id: id} do
      host = start_host(config: nil)

      refute_received {:canary, _config, _opts}
      refute_received {:init, _config}
      assert Host.status(host).engine == :not_configured
      assert Host.open_stream(host, id, %{}) == {:error, :not_configured}
      assert Host.push_au(host, id, <<0>>, 0, {1, 90_000}) == {:error, :no_stream}
    end

    test "an absent NIF library is a state, not a crash", %{id: id} do
      control(%{available?: false})
      host = start_host()

      # nothing is probed and nothing is loaded: there is no library to load into
      refute_received {:canary, _config, _opts}
      refute_received {:init, _config}

      status = Host.status(host)
      assert {:nif_unavailable, _reason} = status.engine
      assert {:unavailable, _reason} = status.nif
      assert {:error, {:nif_unavailable, _reason}} = Host.open_stream(host, id, %{})
    end

    test "a config the crate could not decode is refused before the canary" do
      log = capture_log(fn -> Host.status(start_host(config: %{model: "m.onnx", typo: 1})) end)

      refute_received {:canary, _config, _opts}
      assert log =~ "config is not usable"
    end
  end

  describe "streams" do
    test "open, push, close", %{id: id} do
      host = start_host()
      assert_receive {:init, _config}

      assert {:ok, epoch} = Host.open_stream(host, id, %{})
      assert is_binary(epoch)
      assert_receive {:open_stream, {:engine, "m.onnx"}, ^id, params}
      # every key the crate's decode requires, epoch included
      assert %{min_score: %{}, motion_json: nil, track_floor_json: nil, stream_epoch: ^epoch} =
               params

      assert Host.push_au(host, id, <<1, 2, 3>>, 90, {1, 90_000}) == {:ok, {[], []}}
      assert Host.status(host).streams == [id]

      assert Host.close_stream(host, id) == :ok
      assert_receive {:close_stream, {:stream, ^id}}
      assert Host.status(host).streams == []
      # the ETS handle goes with it, so the hot path stops finding a dead stream
      assert Host.push_au(host, id, <<1>>, 0, {1, 90_000}) == {:error, :no_stream}
    end

    test "the operator-owned scene knobs reach the crate unchanged", %{id: id} do
      host = start_host()

      assert {:ok, _epoch} =
               Host.open_stream(host, id, %{
                 min_score: %{"person" => 0.8},
                 motion_json: ~s({"enabled":true})
               })

      assert_receive {:open_stream, _engine, ^id,
                      %{min_score: %{"person" => 0.8}, motion_json: ~s({"enabled":true})}}
    end

    test "reopening a camera closes the stream it had", %{id: id} do
      host = start_host()

      {:ok, _epoch} = Host.open_stream(host, id, %{})
      assert_receive {:open_stream, _engine, ^id, _params}

      {:ok, _epoch} = Host.open_stream(host, id, %{})
      assert_receive {:close_stream, {:stream, ^id}}
      assert_receive {:open_stream, _engine, ^id, _params}
      assert Host.status(host).streams == [id]
    end

    test "an open the crate refuses leaves no stream behind", %{id: id} do
      control(%{open_stream: {:error, {:open_stream, "no decoder"}}})
      host = start_host()

      assert Host.open_stream(host, id, %{}) == {:error, {:open_stream, "no decoder"}}
      assert Host.status(host).streams == []
    end
  end

  describe "error classes" do
    test "a stream-fatal reason drops that stream and nothing else", %{id: id} do
      other = id <> "_b"
      control(%{push_au: {:error, {:poisoned, "a previous call panicked"}}})
      host = start_host()
      {:ok, _epoch} = Host.open_stream(host, id, %{})
      {:ok, _epoch} = Host.open_stream(host, other, %{})

      assert {:error, {:poisoned, _}} = Host.push_au(host, id, <<1>>, 0, {1, 90_000})

      assert_receive {:close_stream, {:stream, ^id}}
      assert Host.status(host).streams == [other]
      assert Host.status(host).engine == :ready
    end

    test "an engine-fatal reason takes the engine, not just the stream", %{id: id} do
      other = id <> "_b"
      control(%{push_au: {:error, {:model_poisoned, "the shared model lock is poisoned"}}})
      host = start_host()
      {:ok, _epoch} = Host.open_stream(host, id, %{})
      {:ok, _epoch} = Host.open_stream(host, other, %{})

      log =
        capture_log(fn ->
          assert {:error, {:model_poisoned, _}} = Host.push_au(host, id, <<1>>, 0, {1, 90_000})
          # the status call is what proves the host processed the report
          assert {:model_poisoned, _message} = Host.status(host).engine
        end)

      assert log =~ "dead for every camera"
      # every camera, not the one that reported it: the handle serves none of them
      assert Host.status(host).streams == []
      assert {:error, {:model_poisoned, _}} = Host.open_stream(host, other, %{})

      # ...and only a fresh init behind the canary brings one back
      control(%{push_au: nil})
      assert {:ok, status} = Host.configure(host, %{model: "m.onnx"})
      assert status.engine == :ready
    end

    test "a stream-fatal report from a retired open cannot close its replacement", %{id: id} do
      caller = self()

      control(%{
        push_au: fn _stream, _au, _pts, _time_base ->
          send(caller, {:entered, self()})

          receive do
            :release -> {:error, {:poisoned, "a previous call panicked"}}
          end
        end
      })

      host = start_host()
      {:ok, _epoch} = Host.open_stream(host, id, %{})
      pusher = spawn(fn -> Host.push_au(host, id, <<1>>, 0, {1, 90_000}) end)
      assert_receive {:entered, ^pusher}

      # The reopen races the push it retires: `close_stream` waits on the old
      # push's mutex, but the new stream can be open before the caller that lost
      # it is scheduled to report what happened on the old one.
      control(%{open_stream: {:ok, {:stream, :reopened}}})
      {:ok, _epoch} = Host.open_stream(host, id, %{})
      assert_receive {:close_stream, {:stream, ^id}}
      assert_receive {:open_stream, _engine, ^id, _params}

      ref = Process.monitor(pusher)
      send(pusher, :release)
      assert_receive {:DOWN, ^ref, :process, ^pusher, :normal}

      # the status call is what proves the host processed the report
      assert Host.status(host).streams == [id]
      refute_received {:close_stream, {:stream, :reopened}}
    end

    test "a decode error is neither: it is one frame", %{id: id} do
      control(%{push_au: {:error, {:decode, "no video stream"}}})
      host = start_host()
      {:ok, _epoch} = Host.open_stream(host, id, %{})

      assert {:error, {:decode, _}} = Host.push_au(host, id, <<1>>, 0, {1, 90_000})

      assert Host.status(host).streams == [id]
      assert Host.status(host).engine == :ready
    end
  end

  describe "epochs" do
    test "the media session's epoch is adopted and re-announced", %{id: id} do
      # what `Cairn.FFmpegPort` minted for the session the access units come from
      minted = StreamEpochs.new_epoch(id, :started)
      StreamEpochs.subscribe()
      host = start_host()

      assert {:ok, ^minted} = Host.open_stream(host, id, %{stream_epoch: minted})
      assert_receive {:stream_epoch, ^id, ^minted, :started}
      # adopted, never replaced: a fresh ULID here would retire the epoch the
      # ring buffer's init segments already carry
      assert StreamEpochs.current(id) == {:ok, minted}
    end

    test "a camera nobody has minted for gets one, once", %{id: id} do
      StreamEpochs.subscribe()
      host = start_host()

      assert {:ok, epoch} = Host.open_stream(host, id, %{})
      assert_receive {:stream_epoch, ^id, ^epoch, :started}
      assert StreamEpochs.current(id) == {:ok, epoch}
      # the mint broadcast once; the host does not echo its own
      refute_receive {:stream_epoch, ^id, ^epoch, :started}, 50
    end

    test "closing a stream announces nothing — the camera did not stop", %{id: id} do
      host = start_host()
      {:ok, _epoch} = Host.open_stream(host, id, %{})
      StreamEpochs.subscribe()

      assert Host.close_stream(host, id) == :ok
      refute_receive {:stream_epoch, ^id, _epoch, _reason}, 50
    end

    test "an engine reload reopens every stream under its own epoch", %{id: id} do
      minted = StreamEpochs.new_epoch(id, :started)
      host = start_host()
      {:ok, ^minted} = Host.open_stream(host, id, %{stream_epoch: minted})

      StreamEpochs.subscribe()
      assert {:ok, status} = Host.configure(host, %{model: "other.onnx"})
      assert status.model == "other.onnx"

      # the old stream is closed, the model is re-probed and re-loaded, and the
      # stream comes back on the epoch its media session is still running under
      assert_receive {:close_stream, {:stream, ^id}}
      assert_receive {:canary, %{model: "other.onnx"}, _opts}
      assert_receive {:init, %{model: "other.onnx"}}
      assert_receive {:open_stream, {:engine, "other.onnx"}, ^id, %{stream_epoch: ^minted}}
      assert_receive {:stream_epoch, ^id, ^minted, :started}
      assert StreamEpochs.current(id) == {:ok, minted}
    end
  end

  describe "health check" do
    defp health(extra \\ []) do
      [health: Keyword.merge([cpu_baseline_ms: 45.0, min_ratio: 3.0, min_samples: 3], extra)]
    end

    defp push(host, id, count) do
      Enum.each(1..count, fn n -> Host.push_au(host, id, <<n>>, n, {1, 90_000}) end)
    end

    defp slow_push(millis) do
      fn _stream, _au, _pts, _time_base ->
        Process.sleep(millis)
        {:ok, {[], []}}
      end
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
      control(%{push_au: slow_push(8)})
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
      control(%{push_au: slow_push(8)})
      host = start_host(health(cpu_baseline_ms: 15.0))
      ids = for n <- 1..4, do: "#{id}_#{n}"
      Enum.each(ids, &Host.open_stream(host, &1, %{}))

      # start the window here, so it measures the burst and not the setup
      Host.check_health(host)

      ids
      |> Enum.map(fn camera -> Task.async(fn -> push(host, camera, 10) end) end)
      |> Task.await_many(10_000)

      assert Host.check_health(host) == :saturated
      assert Host.status(host).stream_health == Map.new(ids, &{&1, :slow})
    end

    test "one stream failing is that stream, not the accelerator", %{id: id} do
      healthy = id <> "_ok"
      host = start_host(health())
      {:ok, _epoch} = Host.open_stream(host, id, %{})
      {:ok, _epoch} = Host.open_stream(host, healthy, %{})

      push(host, healthy, 5)
      control(%{push_au: {:error, {:infer, "the model pass failed"}}})
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

      control(%{push_au: {:error, {:infer, "the model pass failed"}}})
      push(host, id, 5)
      control(%{push_au: nil})
      push(host, quiet, 3)

      # one camera failing and one with too few completions to have a p50 is not
      # "every stream with traffic is failing"
      assert capture_log(fn -> assert Host.check_health(host) == :unknown end) == ""
      assert Host.status(host).stream_health == %{id => :failing, quiet => :unknown}
    end

    test "every stream failing at once is the accelerator", %{id: id} do
      other = id <> "_b"
      control(%{push_au: {:error, {:infer, "the model pass failed"}}})
      host = start_host(health())
      {:ok, _epoch} = Host.open_stream(host, id, %{})
      {:ok, _epoch} = Host.open_stream(host, other, %{})

      push(host, id, 5)
      push(host, other, 5)

      assert capture_log(fn -> assert Host.check_health(host) == :wedged end) =~ "FAILED"
    end

    test "calls that go in and never come back are a wedge, not silence", %{id: id} do
      caller = self()

      control(%{
        push_au: fn _stream, _au, _pts, _time_base ->
          send(caller, :entered)
          Process.sleep(:infinity)
        end
      })

      host = start_host(health())
      {:ok, _epoch} = Host.open_stream(host, id, %{})
      spawn(fn -> Host.push_au(host, id, <<1>>, 0, {1, 90_000}) end)
      assert_receive :entered, 1_000

      # the window the call was submitted in cannot tell a hang from a window
      # that merely ended mid-call; the next one, with nothing new submitted and
      # the call still outstanding, can
      assert Host.check_health(host) == :idle
      assert capture_log(fn -> assert Host.check_health(host) == :wedged end) =~ "FAILED"
    end

    test "a caller killed mid-call is not a wedge, and does not become one", %{id: id} do
      caller = self()

      control(%{
        push_au: fn _stream, _au, _pts, _time_base ->
          send(caller, :entered)
          Process.sleep(:infinity)
        end
      })

      host = start_host(health())
      {:ok, _epoch} = Host.open_stream(host, id, %{})
      pusher = spawn(fn -> Host.push_au(host, id, <<1>>, 0, {1, 90_000}) end)
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

    test "a backend with no CPU baseline has no ratio to judge", %{id: id} do
      host = start_host(health: [min_samples: 3])
      {:ok, _epoch} = Host.open_stream(host, id, %{})

      push(host, id, 5)
      assert Host.check_health(host) == :not_applicable
    end

    test "a host with no engine has no opinion" do
      host = start_host(config: nil)
      assert Host.check_health(host) == :unknown
    end
  end
end
