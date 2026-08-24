defmodule Cairn.Native.HostTest do
  # `Cairn.NativeStub` and `Cairn.CanaryStub` are driven through one global
  # control map, and the epoch assertions ride the application-wide PubSub.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Cairn.CanaryStub
  alias Cairn.Native.Health
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
    {health, opts} = Keyword.pop(opts, :health, [])

    defaults = [
      name: name,
      native_module: NativeStub,
      ort_module: Cairn.CairnOrtStub,
      canary_module: CanaryStub,
      config: %{model: "m.onnx", backend: "qnn"}
    ]

    start_supervised!({Host, Keyword.merge(defaults, opts)}, id: name)
    # Its own child, as in the supervisor: the host answers `status/2` with the
    # verdict, and never reaches one itself.
    start_supervised!({Health, Keyword.put(health, :host, name)}, id: Health.name(name))

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

    test "an operator's deliberate bypass still loads the model" do
      control(%{canary: {:skipped, :disabled}})
      host = start_host()

      assert_receive {:init, _config}
      assert Host.status(host).canary == {:skipped, :disabled}
      assert Host.status(host).engine == :ready
    end

    test "a missing plugin binary refuses the load rather than skipping the probe", %{id: id} do
      log =
        capture_log(fn ->
          host =
            start_host(
              canary_module: Cairn.Native.Canary,
              canary: [binary: "/nonexistent/cairn-detect"]
            )

          assert {:canary_failed, message} = Host.status(host).engine
          assert message =~ "/nonexistent/cairn-detect"
          assert {:error, {:canary_failed, _message}} = Host.open_stream(host, id, %{})
        end)

      # the whole point of the probe: nothing was loaded into this VM
      refute_received {:init, _config}
      assert log =~ "was NOT loaded in this VM"
    end

    test "no model configured leaves the host inert and up", %{id: id} do
      host = start_host(config: nil)

      refute_received {:canary, _config, _opts}
      refute_received {:init, _config}
      assert Host.status(host).engine == :not_configured
      assert Host.open_stream(host, id, %{}) == {:error, :not_configured}
      assert NativeStub.host_push(host, id) == {:error, :no_stream}
    end

    test "an absent NIF library is a state, not a crash", %{id: id} do
      # The model library (cairn-ort) is what gates the engine; the decode
      # library's absence surfaces per camera at open_decoder instead.
      control(%{ort_available?: false})
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

  describe "the decoder-failure record" do
    test "a refused open lands on status, and the next success clears it", %{id: id} do
      host = start_host()
      assert_receive {:init, _config}

      refusal = {:open_stream, "decoder v4l2 was named but did not open"}
      control(%{open_decoder: {:error, refusal}})
      assert {:error, ^refusal} = Host.open_decoder(host, id, %{}, {2560, 1920})
      assert Host.status(host).decoder_failures == %{id => refusal}

      # The cooldown retry that succeeds is also what clears the surface.
      control(%{open_decoder: nil})
      assert {:ok, _handle} = Host.open_decoder(host, id, %{}, {2560, 1920})
      assert Host.status(host).decoder_failures == %{}
    end

    test "a malformed source is a config error, not a host crash", %{id: id} do
      host = start_host()
      assert_receive {:init, _config}

      assert {:error, {:config, message}} = Host.open_decoder(host, id, %{}, [2560, 1920])
      assert message =~ "{width, height}"
      # The host survived to answer — the failure was a value, not an exit —
      # and the camera it strands is on the surface like any other refusal:
      # a caller bug repeats identically on every retry, so status saying why
      # beats a camera that reads healthy at 0 fps.
      assert Host.status(host).engine == :ready
      assert %{^id => {:config, ^message}} = Host.status(host).decoder_failures
    end

    test "an out-of-range source is refused before the NIF's own decode", %{id: id} do
      host = start_host()
      assert_receive {:init, _config}

      # Negative and past-i32 pairs would both pass an is_integer guard and
      # then raise badarg inside the NIF's argument decode — in the host's own
      # handle_call.
      for source <- [{0, 1920}, {-2560, 1920}, {2560, -1}, {2_147_483_648, 1920}] do
        assert {:error, {:config, message}} = Host.open_decoder(host, id, %{}, source)
        assert message =~ "positive"
      end

      # No open attempt ever reached the native module.
      refute_received {:open_decoder, _camera_id, _params}
      assert Host.status(host).engine == :ready
    end

    test "a params-vocabulary refusal is recorded like any other", %{id: id} do
      host = start_host()
      assert_receive {:init, _config}

      assert {:error, {:config, message}} =
               Host.open_decoder(host, id, %{typo: 1}, {2560, 1920})

      # Same argument as the malformed source: this camera retries into the
      # identical refusal for ever, so the surface must say why.
      assert %{^id => {:config, ^message}} = Host.status(host).decoder_failures
    end

    test "a settle-time refusal lands on status after the open succeeded", %{id: id} do
      host = start_host()
      assert_receive {:init, _config}

      # The deferred probe's shape: the open succeeds (and clears nothing,
      # there was nothing), the refusal arrives later from the pipeline.
      assert {:ok, _handle} = Host.open_decoder(host, id, %{}, {2560, 1920})
      message = "decoder v4l2 was named but did not open"
      Host.report_decoder_refusal(host, id, message)

      assert %{^id => {:decoder_refused, ^message}} = Host.status(host).decoder_failures

      # The next successful open — a fixed profile, a reload — clears it.
      assert {:ok, _handle} = Host.open_decoder(host, id, %{}, {2560, 1920})
      assert Host.status(host).decoder_failures == %{}
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

      # the crate's frames reach the caller untouched — `infer_us` is the stub's
      # timing of its own call, which only the health report reads
      assert {:ok, {[%{inferred: true, objects: []}], []}} =
               NativeStub.host_push(host, id, 90)

      assert Host.status(host).streams == [id]

      assert Host.close_stream(host, id) == :ok
      assert_receive {:close_stream, {:stream, ^id}}
      assert Host.status(host).streams == []
      # the ETS handle goes with it, so the hot path stops finding a dead stream
      assert NativeStub.host_push(host, id) == {:error, :no_stream}
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

  describe "native teardown" do
    # What a `push_frame/5` wedged on the crate's per-stream mutex does to
    # `close_stream`: it does not return until the push does.
    defp blocking_close(caller) do
      fn _stream ->
        send(caller, {:closing, self()})

        receive do
          :release -> {:ok, true}
        end
      end
    end

    defp eventually(fun, attempts \\ 200) do
      cond do
        fun.() ->
          :ok

        attempts == 0 ->
          flunk("the host never got there")

        true ->
          Process.sleep(10)
          eventually(fun, attempts - 1)
      end
    end

    test "a close that blocks in the crate leaves the host answering", %{id: id} do
      control(%{close_stream: blocking_close(self())})
      host = start_host(health: [interval_ms: 25])

      {:ok, _epoch} = Host.open_stream(host, id, %{})
      assert Host.close_stream(host, id) == :ok
      assert_receive {:closing, closer}

      assert Host.status(host).streams == []
      # the monitor's own timer, not `check_health/1`: the verdict has to reach the
      # status surface with nobody asking for it
      eventually(fn -> Host.status(host).health == :idle end)

      send(closer, :release)
    end

    test "the handle is gone before the native close lands", %{id: id} do
      control(%{close_stream: blocking_close(self())})
      host = start_host()

      {:ok, _epoch} = Host.open_stream(host, id, %{})
      assert Host.close_stream(host, id) == :ok
      assert_receive {:closing, closer}

      assert :ets.lookup(host, id) == []
      assert Host.status(host).streams == []
      assert NativeStub.host_push(host, id) == {:error, :no_stream}

      send(closer, :release)
    end

    test "the close is made by a task under the application's supervisor", %{id: id} do
      control(%{close_stream: blocking_close(self())})
      host = start_host()

      {:ok, _epoch} = Host.open_stream(host, id, %{})
      assert Host.close_stream(host, id) == :ok

      # the call was really made, and not by this host
      assert_receive {:close_stream, {:stream, ^id}}
      assert_receive {:closing, closer}
      refute closer == Process.whereis(host)
      assert closer in Task.Supervisor.children(Cairn.TaskSupervisor)

      send(closer, :release)
    end

    test "a blocked close does not eat the shutdown budget", %{id: id} do
      control(%{close_stream: blocking_close(self())})
      name = start_host()

      {:ok, _epoch} = Host.open_stream(name, id, %{})

      started = System.monotonic_time(:millisecond)
      stop_supervised!(name)
      elapsed = System.monotonic_time(:millisecond) - started

      # handed off on the way out, and outliving the process that handed it over
      assert_receive {:closing, closer}
      assert elapsed < 1_000, "shutting the host down took #{elapsed} ms"

      send(closer, :release)
    end

    test "a reopen behind a close that has not landed is refused, legibly", %{id: id} do
      control(%{close_stream: blocking_close(self())})
      host = start_host(close_wait_ms: 50)

      {:ok, _epoch} = Host.open_stream(host, id, %{})
      assert Host.close_stream(host, id) == :ok
      assert_receive {:closing, closer}

      # The crate holds the camera id until the close lands, so this open cannot
      # succeed — and says why, rather than being refused as a duplicate.
      assert {:error, {:closing, message}} = Host.open_stream(host, id, %{})
      assert message =~ id
      assert Host.status(host).closing == [id]

      # ...and the camera comes back once the wedged close returns
      control(%{close_stream: nil})
      send(closer, :release)
      eventually(fn -> Host.status(host).closing == [] end)
      assert {:ok, _epoch} = Host.open_stream(host, id, %{})
    end
  end

  describe "error classes" do
    test "a stream-fatal reason drops that stream and nothing else", %{id: id} do
      other = id <> "_b"
      control(%{push_frame: {:error, {:poisoned, "a previous call panicked"}}})
      host = start_host()
      {:ok, _epoch} = Host.open_stream(host, id, %{})
      {:ok, _epoch} = Host.open_stream(host, other, %{})

      assert {:error, {:poisoned, _}} = NativeStub.host_push(host, id)

      assert_receive {:close_stream, {:stream, ^id}}
      assert Host.status(host).streams == [other]
      assert Host.status(host).engine == :ready
    end

    test "an engine-fatal reason takes the engine, not just the stream", %{id: id} do
      other = id <> "_b"
      control(%{push_frame: {:error, {:model_poisoned, "the shared model lock is poisoned"}}})
      host = start_host()
      {:ok, _epoch} = Host.open_stream(host, id, %{})
      {:ok, _epoch} = Host.open_stream(host, other, %{})

      log =
        capture_log(fn ->
          assert {:error, {:model_poisoned, _}} = NativeStub.host_push(host, id)
          # the status call is what proves the host processed the report
          assert {:model_poisoned, _message} = Host.status(host).engine
        end)

      assert log =~ "dead for every camera"
      # every camera, not the one that reported it: the handle serves none of them
      assert Host.status(host).streams == []
      assert {:error, {:model_poisoned, _}} = Host.open_stream(host, other, %{})

      # ...and only a fresh init behind the canary brings one back
      control(%{push_frame: nil})
      assert {:ok, status} = Host.configure(host, %{model: "m.onnx"})
      assert status.engine == :ready
    end

    test "a stream-fatal report from a retired open cannot close its replacement", %{id: id} do
      caller = self()

      control(%{
        push_frame: fn _stream, _payload, _meta, _time_base ->
          send(caller, {:entered, self()})

          receive do
            :release -> {:error, {:poisoned, "a previous call panicked"}}
          end
        end
      })

      host = start_host()
      {:ok, _epoch} = Host.open_stream(host, id, %{})
      pusher = spawn(fn -> NativeStub.host_push(host, id) end)
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
      control(%{push_frame: {:error, {:decode, "no video stream"}}})
      host = start_host()
      {:ok, _epoch} = Host.open_stream(host, id, %{})

      assert {:error, {:decode, _}} = NativeStub.host_push(host, id)

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
      assert_receive {:stream_epoch, ^id, :main, ^minted, :started}
      # adopted, never replaced: a fresh ULID here would retire the epoch the
      # ring buffer's init segments already carry
      assert StreamEpochs.current(id) == {:ok, minted}
    end

    test "a camera nobody has minted for gets one, once", %{id: id} do
      StreamEpochs.subscribe()
      host = start_host()

      assert {:ok, epoch} = Host.open_stream(host, id, %{})
      assert_receive {:stream_epoch, ^id, :main, ^epoch, :started}
      assert StreamEpochs.current(id) == {:ok, epoch}
      # the mint broadcast once; the host does not echo its own
      refute_receive {:stream_epoch, ^id, :main, ^epoch, :started}, 50
    end

    test "closing a stream announces nothing — the camera did not stop", %{id: id} do
      host = start_host()
      {:ok, _epoch} = Host.open_stream(host, id, %{})
      StreamEpochs.subscribe()

      assert Host.close_stream(host, id) == :ok
      refute_receive {:stream_epoch, ^id, :main, _epoch, _reason}, 50
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
      assert_receive {:stream_epoch, ^id, :main, ^minted, :started}
      assert StreamEpochs.current(id) == {:ok, minted}
    end
  end

  describe "the model a profile asks for" do
    @stub_onnx "test/support/fixtures/models/stub.onnx"

    defp membrane_config(profile) do
      {:ok, config, _warnings} =
        Cairn.Config.from_map(%{
          "data_dir" => "tmp/host_test",
          "udp" => %{"base_port" => 17_000, "range" => 20},
          "profile_dirs" => ["test/support/fixtures/profiles/argv"],
          "plugins" => %{"det" => %{"command" => "./p", "profile" => profile}},
          "cameras" => [
            %{
              "id" => "cam_a",
              "rtsp_url" => "rtsp://h/1",
              "pipeline" => "membrane",
              "plugin" => "det"
            }
          ]
        })

      config
    end

    defp start_profiled(profile, opts \\ []) do
      start_host(
        Keyword.merge([config: nil, config_source: fn -> membrane_config(profile) end], opts)
      )
    end

    test "is loaded when nothing pins one" do
      host = start_profiled("full")

      assert_receive {:canary, %{model: @stub_onnx, model_profile: "yolox"}, _opts}
      assert_receive {:init, %{model: @stub_onnx, backend: "ort", input_size: "416"}}
      assert Host.status(host).model == @stub_onnx
    end

    test "loses to a model pinned on this node" do
      host = start_profiled("full", config: %{model: "pinned.onnx"})

      assert_receive {:init, %{model: "pinned.onnx"}}
      assert Host.status(host).model == "pinned.onnx"
    end

    test "reaches a running camera on reload, and does not rewrite its scene knobs", %{id: id} do
      minted = StreamEpochs.new_epoch(id, :started)
      host = start_profiled("partial")
      assert_receive {:init, %{model_profile: nil}}

      {:ok, ^minted} =
        Host.open_stream(host, id, %{min_score: %{"person" => 0.8}, stream_epoch: minted})

      assert_receive {:open_stream, _engine, ^id, _params}

      Host.reconfigure(host, membrane_config("full"))

      assert_receive {:close_stream, {:stream, ^id}}
      assert_receive {:canary, %{model_profile: "yolox"}, _opts}
      assert_receive {:init, %{model_profile: "yolox"}}

      # the profile moved the model and nothing else: the reopened stream carries
      # the operator's own scene config, on the epoch its media session is on
      assert_receive {:open_stream, _engine, ^id,
                      %{min_score: %{"person" => 0.8}, stream_epoch: ^minted}}
    end

    test "is left alone by a reload that did not move it", %{id: id} do
      host = start_profiled("full")
      assert_receive {:init, _config}
      {:ok, _epoch} = Host.open_stream(host, id, %{})
      assert_receive {:open_stream, _engine, ^id, _params}

      Host.reconfigure(host, membrane_config("full"))

      # a model reload costs every stream on this node its history
      refute_receive {:init, _config}, 50
      refute_receive {:close_stream, _stream}, 50
      assert Host.status(host).streams == [id]
    end

    test "a reload cannot move a model this node pinned" do
      host = start_profiled("partial", config: %{model: "pinned.onnx"})
      assert_receive {:init, %{model: "pinned.onnx"}}

      Host.reconfigure(host, membrane_config("full"))

      refute_receive {:init, _config}, 50
      assert Host.status(host).model == "pinned.onnx"
    end
  end

  describe "the CPU baseline's venue and cost" do
    # The measurement goes through the CANARY — a fresh, killable OS process —
    # never this VM's ort module: the QNN EP registration is process-wide and
    # permanent, so after the first engine load an in-VM "CPU" session cannot
    # prove its venue (observed on the board: 60.8 ms for a model whose true
    # CPU pass exceeds 40 s, pinning health at a false :wedged on every boot,
    # reload and restart). And ASYNCHRONOUSLY: the subprocess freed the
    # measurement from init ordering, so the engine serves immediately and
    # the number lands when it lands.
    # Event-driven, never timed: monitor the task's own pid for its exit,
    # then drain the host's queue with `:sys.get_state/1` round-trips until
    # the result is consumed — each call is a real synchronization, so no
    # clock is involved anywhere.
    defp settled_baseline(host) do
      case :sys.get_state(host).baseline_task do
        nil ->
          :sys.get_state(host).cpu_baseline_ms

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
      state = :sys.get_state(host)

      if state.baseline_task == nil,
        do: state.cpu_baseline_ms,
        else: drain_baseline(host, attempts - 1)
    end

    test "measures via the canary, after init, in one deadline" do
      host = start_host(config: %{model: @stub_onnx, backend: "qnn"})

      # init is not gated on the measurement
      assert_receive {:init, %{model: @stub_onnx}}
      assert_receive {:cpu_baseline, %{model: @stub_onnx}, 5, opts}
      assert is_integer(opts[:timeout_ms])
      assert settled_baseline(host) == 45.0
      # the in-VM measurement NIF is never consulted
      refute_received {:cpu_baseline_ms, _config, _passes}
    end

    test "a measurement the canary cannot finish yields no baseline" do
      control(%{cpu_baseline: {:error, "no CPU baseline within the timeout: it said nothing"}})

      log =
        capture_log(fn ->
          host = start_host(config: %{model: @stub_onnx, backend: "qnn"})

          assert settled_baseline(host) == nil
        end)

      assert_received {:cpu_baseline, _config, 5, _opts}
      assert log =~ "no CPU baseline"
    end

    test "a model file that does not exist skips the measurement entirely" do
      host = start_host(config: %{model: "m.onnx", backend: "qnn"})

      assert_receive {:init, %{model: "m.onnx"}}
      refute_received {:cpu_baseline, _config, _passes, _opts}
      assert GenServer.call(host, :probe).cpu_baseline_ms == nil
    end
  end
end
