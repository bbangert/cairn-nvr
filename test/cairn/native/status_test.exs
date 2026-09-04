defmodule Cairn.Native.StatusTest do
  # `Cairn.NativeStub`, `Cairn.CanaryStub` and `Cairn.CameraStatus` are all
  # process- or node-global.
  use ExUnit.Case, async: false

  alias Cairn.CameraStatus
  alias Cairn.CanaryStub
  alias Cairn.Native.Health
  alias Cairn.Native.Host
  alias Cairn.Native.Status
  alias Cairn.NativeStub

  @moduletag :capture_log

  @control NativeStub.control()

  setup do
    :persistent_term.put(@control, %{test: self()})
    id = "ns_#{System.unique_integer([:positive])}"

    # `Cairn.CameraStatus` drops a write for a camera its published snapshot
    # does not name, and the reporter under test writes through the real one.
    # The ids here belong to no config, so the application snapshot is lent
    # them for the test — `async: false` is what makes that safe.
    key = Cairn.Config.Server.snapshot_key(Cairn.Config.Server)
    snapshot = :persistent_term.get(key, nil)
    lent = Enum.map([id, id <> "_b"], &%Cairn.Config.Camera{id: &1})
    if snapshot, do: :persistent_term.put(key, %{snapshot | cameras: lent ++ snapshot.cameras})

    on_exit(fn ->
      if snapshot, do: :persistent_term.put(key, snapshot)
      :persistent_term.erase(@control)
      CameraStatus.delete(id)
      CameraStatus.delete(id <> "_b")
    end)

    %{id: id}
  end

  defp control(attrs) do
    :persistent_term.put(@control, Map.merge(:persistent_term.get(@control, %{}), attrs))
  end

  # Host, monitor and reporter are siblings, exactly as the supervisor starts
  # them. The reporter's interval is long: every test here publishes on demand.
  defp start_stack(opts \\ []) do
    name = :"host_#{System.unique_integer([:positive])}"
    # No `cpu_baseline_ms` opt: what the monitor judges by here is what the host
    # measured at engine init, as on a real node.
    {health, opts} = Keyword.pop(opts, :health, min_samples: 3)
    {status, opts} = Keyword.pop(opts, :status, [])

    defaults = [
      name: name,
      native_module: NativeStub,
      ort_module: Cairn.CairnOrtStub,
      canary_module: CanaryStub,
      config: %{model: "test/support/fixtures/models/stub.onnx", backend: "qnn"}
    ]

    start_supervised!({Host, Keyword.merge(defaults, opts)}, id: name)
    start_supervised!({Health, Keyword.put(health, :host, name)}, id: Health.name(name))

    reporter =
      start_supervised!(
        {Status,
         Keyword.merge([host: name, interval_ms: 60_000, name: :"status_#{name}"], status)},
        id: :"status_#{name}"
      )

    %{host: name, reporter: reporter}
  end

  # The reporter reads the config for one thing: which cameras are configured to
  # detect on this node, stream or no stream.
  defp detecting(ids) do
    cameras =
      Enum.map(ids, &%Cairn.Config.Camera{id: &1, plugin: {:group, "det"}})

    fn -> %Cairn.Config{cameras: cameras} end
  end

  defp published(reporter, camera_id) do
    :ok = Status.publish(reporter)
    _flushed = :sys.get_state(CameraStatus)
    CameraStatus.get(camera_id).plugin_status
  end

  describe "the surface" do
    test "a camera detected on natively carries the native fields", %{id: id} do
      %{host: host, reporter: reporter} = start_stack()
      {:ok, _epoch} = Host.open_stream(host, id, %{})
      Enum.each(1..5, &NativeStub.host_push(host, id, &1))
      assert Host.check_health(host) == :healthy

      status = published(reporter, id)

      assert status["state"] == "ready"
      assert status["health"] == "healthy"
      assert status["stream_health"] == "ok"
      assert status["engine"] == "ready"
      assert status["nif"] == "available"
      assert status["canary"] == "passed"
      assert status["model"] == "stub.onnx"
      assert status["backend"] == "qnn"
      assert status["fps"] > 0.0
      assert status["inferences"] == 5
      assert status["p50_ms"] >= 0.0
      # the number the verdict was reached against, measured at engine init
      assert status["cpu_baseline_ms"] == 45.0
    end

    test "a camera with no native stream is never written", %{id: id} do
      %{host: host, reporter: reporter} = start_stack()
      classic = id <> "_classic"
      CameraStatus.put(classic, %{status: :running})
      {:ok, _epoch} = Host.open_stream(host, id, %{})

      assert published(reporter, id)
      assert CameraStatus.get(classic) == %{status: :running, probe: nil, plugin_status: nil}
    end

    test "a stream that goes away takes its status with it", %{id: id} do
      %{host: host, reporter: reporter} = start_stack()
      {:ok, _epoch} = Host.open_stream(host, id, %{})
      assert published(reporter, id)

      :ok = Host.close_stream(host, id)
      refute published(reporter, id)
    end

    # `docs/ha-api.md`: responses never emit on-disk paths, and this map is
    # served verbatim by the camera list and the SSE `camera_status` frame.
    test "the model reaches the surface as a name, never as a path", %{id: id} do
      %{host: host, reporter: reporter} =
        start_stack(config: %{model: "/opt/cairn/models/yolox_nano.onnx", backend: "qnn"})

      {:ok, _epoch} = Host.open_stream(host, id, %{})

      assert published(reporter, id)["model"] == "yolox_nano.onnx"
    end

    test "a refused canary names the model in its detail without the path" do
      control(%{canary: {:error, "the probe process exited with SIGSEGV"}})
      %{host: host} = start_stack(config: %{model: "/opt/cairn/models/yolox_nano.onnx"})

      detail = Status.payload(Host.status(host), "cam")["detail"]

      assert detail =~ "yolox_nano.onnx"
      refute detail =~ "/opt/cairn"
    end

    test "the whole payload survives JSON encoding", %{id: id} do
      %{host: host, reporter: reporter} = start_stack()
      {:ok, _epoch} = Host.open_stream(host, id, %{})

      # the HA camera list and the SSE `camera_status` frame both encode it
      assert {:ok, _json} = Jason.encode(published(reporter, id))
    end
  end

  describe "the four verdicts" do
    defp state_for(health), do: Status.payload(status_map(health: health), "cam")["state"]

    defp status_map(attrs) do
      Map.merge(
        %{
          nif: :available,
          engine: :ready,
          canary: :passed,
          model: "m.onnx",
          backend: "qnn",
          streams: ["cam"],
          health: :healthy,
          decoder_failures: %{},
          stream_health: %{},
          stream_fps: %{},
          p50_ms: 3.0,
          cpu_baseline_ms: 45.0,
          inferences: 10
        },
        Map.new(attrs)
      )
    end

    test "each is a distinct headline, and none collapses into another" do
      states = Map.new([:healthy, :saturated, :wedged, :idle, :unknown], &{&1, state_for(&1)})

      assert states[:healthy] == "ready"
      assert states[:saturated] == "saturated"
      assert states[:wedged] == "wedged"
      assert states[:idle] == "idle"
      # not enough evidence about a loaded engine is not a fault
      assert states[:unknown] == "ready"
      assert length(Enum.uniq(Map.values(states))) == 4
    end

    test "the verdict itself is on the surface, whatever the headline says" do
      for verdict <- [:healthy, :saturated, :wedged, :idle, :unknown, :not_applicable] do
        assert Status.payload(status_map(health: verdict), "cam")["health"] ==
                 Atom.to_string(verdict)
      end
    end

    test "a camera whose decoder open failed is an error, and only that camera" do
      status =
        status_map(
          decoder_failures: %{
            "cam" => {:open_stream, "decoder v4l2 was named but did not open"}
          },
          streams: ["cam", "other"]
        )

      refused = Status.payload(status, "cam")
      # The crate's own message is the account: which backend went unhonoured.
      assert refused["state"] == "error"
      assert refused["detail"] =~ "decoder did not open (open_stream)"
      assert refused["detail"] =~ "decoder v4l2 was named"
      assert refused["detail"] =~ "recording is unaffected"

      # The failure is this camera's, not the node's.
      assert Status.payload(status, "other")["state"] == "ready"
    end

    test "an engine-level failure outranks a recorded decoder failure" do
      status =
        status_map(
          engine: :unanswered,
          decoder_failures: %{"cam" => {:open_stream, "stale"}}
        )

      # The wedge is the story; a stale per-camera entry must not soften it.
      assert Status.payload(status, "cam")["state"] == "wedged"
    end

    test "a status map with no decoder_failures key still answers" do
      # The degraded map a wedged host produces has no such key; the clause
      # reads it with a default rather than requiring it.
      assert Status.payload(status_map([]) |> Map.delete(:decoder_failures), "cam")["state"] ==
               "ready"
    end

    test "a wedge says a restart will not clear it, and saturation says load" do
      wedged = Status.payload(status_map(health: :wedged), "cam")
      saturated = Status.payload(status_map(health: :saturated), "cam")

      assert wedged["detail"] =~ "needs an operator"
      assert wedged["detail"] =~ "kill -9"
      assert saturated["detail"] =~ "sample_fps"
      refute saturated["detail"] =~ "operator"
    end
  end

  describe "the engine's own states" do
    test "a refused canary's message is the reason detection is absent", %{id: id} do
      control(%{canary: {:error, "the probe process exited with SIGSEGV"}})
      %{host: host, reporter: reporter} = start_stack(status: [config_source: detecting([id])])

      # The engine never loaded, so no stream exists — and this is exactly when
      # the surface has something to say: every camera configured to detect is
      # not detecting, and only this reaches the dashboard and the API.
      {:error, _refused} = Host.open_stream(host, id, %{})
      status = published(reporter, id)

      assert status["state"] == "error"
      assert status["canary"] == "failed"
      assert status["detail"] =~ "the probe process exited with SIGSEGV"
      assert status["detail"] =~ "NOT loaded"
    end

    test "a node with no NIF tells every camera configured to detect", %{id: id} do
      control(%{available?: false})
      other = id <> "_b"
      classic = id <> "_classic"
      CameraStatus.put(classic, %{status: :running})

      %{reporter: reporter} =
        start_stack(status: [config_source: detecting([id, other])])

      assert published(reporter, id)["state"] == "error"
      assert published(reporter, other)["detail"] =~ "cairn-native is not loaded"
      # a classic camera's own plugin reports for it, and must not be overwritten
      assert CameraStatus.get(classic).plugin_status == nil
    end

    test "a long canary message is cut to whole graphemes, not to bytes", %{id: id} do
      # 300 em-dashes: every byte boundary inside one is a cut that would leave
      # the detail unencodable, and the truncation lands in the middle of them
      control(%{canary: {:error, String.duplicate("—", 300)}})
      %{host: host} = start_stack()

      detail = Status.payload(Host.status(host), id)["detail"]

      assert byte_size(detail) <= 256
      assert String.valid?(detail)
      assert {:ok, _json} = Jason.encode(%{"detail" => detail})
    end

    test "a missing NIF is named, not a silent absence" do
      control(%{available?: false})
      %{host: host} = start_stack()

      status = Status.payload(Host.status(host), "cam")

      assert status["state"] == "error"
      assert status["nif"] == "unavailable"
      assert status["detail"] =~ "cairn-native is not loaded"
    end

    test "an engine-fatal load failure carries its message" do
      control(%{init: {:error, {:model_load, "the graph would not compile"}}})
      %{host: host} = start_stack()

      status = Status.payload(Host.status(host), "cam")

      assert status["engine"] == "model_load"
      assert status["detail"] =~ "the graph would not compile"
    end

    test "a host that does not answer is the wedge itself", %{id: id} do
      %{host: host, reporter: reporter} = start_stack(status: [timeout_ms: 100])
      {:ok, _epoch} = Host.open_stream(host, id, %{})
      assert published(reporter, id)

      # `open_stream` is the one native call made in the host process, so a stub
      # that never returns from it leaves the host inside a native call
      control(%{open_stream: fn _engine, _id, _params -> Process.sleep(:infinity) end})
      spawn(fn -> Host.open_stream(host, id <> "_b", %{}) end)

      wedged = wait_for_wedge(reporter, id)
      assert wedged["state"] == "wedged"
      assert wedged["health"] == "wedged"
      assert wedged["detail"] =~ "needs an operator"
    end

    defp wait_for_wedge(reporter, camera_id, attempts \\ 50) do
      case published(reporter, camera_id) do
        %{"state" => "wedged"} = status -> status
        _not_yet when attempts > 0 -> wait_for_wedge(reporter, camera_id, attempts - 1)
        status -> status
      end
    end
  end
end
