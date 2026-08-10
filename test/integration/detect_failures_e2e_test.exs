defmodule Cairn.DetectFailuresE2ETest do
  @moduledoc """
  The failure paths the happy-path E2E (`Cairn.MembraneE2ETest`) never
  exercises, through the same real stack: a refused canary, an absent
  inference library, and a model that will not load. What each must prove is
  the same three things — the camera keeps recording, the detect branch goes
  dark rather than crash-looping, and the failure is *visible* (status/engine
  state), because phase 3's review lesson was exactly that protective
  machinery can exist and never run.

  Excluded by default (`test/test_helper.exs`); runs with the e2e artifacts:

      mix test --only e2e_membrane
  """

  use Cairn.DataCase, async: false

  alias Cairn.{CameraStatus, Config, Event, RingBuffer}
  alias Cairn.Config.Camera
  alias Cairn.Native
  alias Cairn.Native.Host

  @moduletag :e2e_membrane
  @moduletag timeout: 300_000
  @moduletag :capture_log

  @model "plugins/cairn-detect/yolox_nano.onnx"
  @labels "plugins/cairn-detect/coco.names"
  @plugin "plugins/cairn-detect/target/release/cairn-detect"
  @clip "data/events/reolink_main/08e15adf-b1c8-4217-b6a0-d201f253c54b_reolink_main_1785901116.mp4"

  setup_all do
    unless Native.available?() and CairnOrt.available?() do
      raise "both NIF libraries are required: cargo build --release in " <>
              "plugins/cairn-native and plugins/cairn-ort, copy the .so files " <>
              "to priv/native/"
    end

    for path <- [@model, @labels, @plugin, @clip] do
      unless File.exists?(path), do: raise("#{path} is missing")
    end

    previous = Application.get_env(:cairn, Cairn.Native.Canary, [])
    Application.put_env(:cairn, Cairn.Native.Canary, Keyword.put(previous, :binary, @plugin))
    on_exit(fn -> Application.put_env(:cairn, Cairn.Native.Canary, previous) end)

    :ok
  end

  setup %{test: test} do
    id = "e2e_fail_#{:erlang.phash2(test)}"

    camera = %Camera{
      id: id,
      rtsp_url: "file://" <> Path.absname(@clip),
      plugin: {:group, "native"},
      min_score: %{"default" => 0.4},
      pipeline: :membrane
    }

    config = %Config{
      data_dir: Config.Server.get().data_dir,
      udp_base_port: 19_700,
      udp_port_range: 10,
      pre_window_seconds: 2,
      post_window_seconds: 3,
      max_event_seconds: 30,
      cameras: [camera]
    }

    %{camera: camera, config: config, id: id}
  end

  # The three proofs every failure case owes, after the camera has streamed
  # for a while under a broken detector.
  defp assert_dark_branch_healthy_recording(id) do
    Event.subscribe()

    # Recording: the ring accumulates real fragments regardless of detection.
    wait_until(fn ->
      match?({:ok, %{fragments: [_ | _]}}, RingBuffer.fetch_recent(id, 10))
    end)

    # The camera itself reports a running session.
    wait_until(fn -> match?(%{status: :running}, CameraStatus.get(id)) end)

    # …and the dark branch produced no event in a window that the healthy
    # E2E's clip fills with cars almost immediately.
    refute_receive {:event_started, %Event{camera_id: ^id}}, 8_000
  end

  defp wait_until(fun, deadline_ms \\ 30_000) do
    poll(fun, System.monotonic_time(:millisecond) + deadline_ms)
  end

  defp poll(fun, deadline) do
    cond do
      fun.() not in [false, nil] ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        raise "condition never held"

      true ->
        Process.sleep(100)
        poll(fun, deadline)
    end
  end

  test "a refused canary leaves the camera recording and the refusal visible",
       %{camera: camera, config: config, id: id} do
    # A real refusal from the real plugin binary: the model path does not
    # exist, so the probe load exits nonzero before the in-VM NIF ever sees it.
    {:error, {:canary_failed, message}} =
      Host.configure(%{
        model: "does/not/exist.onnx",
        labels: @labels,
        backend: "ort",
        decoder: "sw",
        sample_fps: 5
      })

    assert message =~ "does/not/exist.onnx"
    assert {:canary_failed, _} = Host.status().engine
    assert {:failed, _} = Host.status().canary

    start_supervised!({Cairn.Camera, camera: camera, config: config, index: 0})
    assert_dark_branch_healthy_recording(id)
  after
    restore_engine()
  end

  test "a model that will not load is an engine state, not a crash loop",
       %{camera: camera, config: config, id: id} do
    # The canary is bypassed so the refusal has to come from the in-VM load
    # itself — the other half of the protection. Restored in this test's
    # `after`, which must run before `restore_engine/0` reconfigures — an
    # `on_exit` would run too late and reload the good model unrehearsed.
    previous = Application.get_env(:cairn, Cairn.Native.Canary, [])
    Application.put_env(:cairn, Cairn.Native.Canary, Keyword.put(previous, :enabled, false))

    {:error, {:model_load, message}} =
      Host.configure(%{
        model: "does/not/exist.onnx",
        labels: @labels,
        backend: "ort",
        decoder: "sw",
        sample_fps: 5
      })

    assert message =~ "exist.onnx"
    assert {:model_load, _} = Host.status().engine

    start_supervised!({Cairn.Camera, camera: camera, config: config, index: 0})
    assert_dark_branch_healthy_recording(id)
  after
    previous = Application.get_env(:cairn, Cairn.Native.Canary, [])
    Application.put_env(:cairn, Cairn.Native.Canary, Keyword.delete(previous, :enabled))
    restore_engine()
  end

  test "an absent inference library is a state the whole pipeline survives",
       %{camera: camera, config: config, id: id} do
    # The library is already loaded in this VM (asserted in setup_all), so
    # absence is simulated at the exact seam `CairnOrt.available?/0` reads:
    # its recorded load result. This is the one failure that cannot be
    # produced for real without a second VM. Restored in this test's `after`,
    # which must run before `restore_engine/0` reconfigures.
    :persistent_term.put({CairnOrt, :load_result}, {:error, :simulated_absence})

    {:error, {:nif_unavailable, :simulated_absence}} =
      Host.configure(%{
        model: @model,
        labels: @labels,
        backend: "ort",
        decoder: "sw",
        sample_fps: 5
      })

    assert {:nif_unavailable, _} = Host.status().engine
    assert {:unavailable, :simulated_absence} = Host.status().nif

    start_supervised!({Cairn.Camera, camera: camera, config: config, index: 0})
    assert_dark_branch_healthy_recording(id)
  after
    :persistent_term.put({CairnOrt, :load_result}, :ok)
    restore_engine()
  end

  # Every case leaves the singleton engine broken on purpose; hand the next
  # test (and the sibling E2E module) a working one back.
  defp restore_engine do
    {:ok, _status} =
      Host.configure(%{
        model: @model,
        labels: @labels,
        backend: "ort",
        decoder: "sw",
        sample_fps: 5
      })
  end
end
