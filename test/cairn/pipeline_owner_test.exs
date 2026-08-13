defmodule Cairn.PipelineOwnerTest do
  use ExUnit.Case, async: false

  alias Cairn.Config
  alias Cairn.Config.Camera
  alias Cairn.{Fragment, PipelineOwner, RegistryHelpers, RingBuffer, StreamEpochs}

  defmodule StubPipeline do
    @moduledoc """
    Stands in for `Cairn.Pipeline.Camera`: announces every birth to the test
    with the options it was handed, and relays what the owner sends it.
    """
    use Membrane.Pipeline

    @impl true
    def handle_init(_ctx, opts) do
      test = :persistent_term.get({__MODULE__, Keyword.fetch!(opts, :camera).id})
      send(test, {:pipeline_started, self(), opts})
      {[], %{test: test}}
    end

    @impl true
    def handle_info(message, _ctx, state) do
      send(state.test, {:pipeline_msg, self(), message})
      {[], state}
    end
  end

  defmodule StubBridge do
    @moduledoc "A `Cairn.FFmpegPort` for the watchdog's bridge ladder."
    use GenServer

    def start_link({camera_id, test, running?}) do
      GenServer.start_link(__MODULE__, {test, running?},
        name: Cairn.Registry.via(camera_id, :ffmpeg)
      )
    end

    @impl true
    def init({test, running?}), do: {:ok, %{test: test, running?: running?}}

    @impl true
    def handle_call(:running?, _from, state), do: {:reply, state.running?, state}

    @impl true
    def handle_cast(:bounce, state) do
      send(state.test, :bounced)
      {:noreply, state}
    end
  end

  defmodule StubBridgePipeline do
    @moduledoc """
    Like `StubPipeline`, but also registers itself under `:bridge_source` —
    the real `BridgeSource` element's own hard-matched registration
    (`bridge_source.ex:44`) — so a test can hold that entry's stale-registry
    window open across a rebuild.
    """
    use Membrane.Pipeline

    @impl true
    def handle_init(_ctx, opts) do
      camera = Keyword.fetch!(opts, :camera)
      {:ok, _pid} = Cairn.Registry.register(camera.id, :bridge_source)
      test = :persistent_term.get({StubPipeline, camera.id})
      send(test, {:pipeline_started, self(), opts})
      {[], %{test: test}}
    end

    @impl true
    def handle_info(message, _ctx, state) do
      send(state.test, {:pipeline_msg, self(), message})
      {[], state}
    end
  end

  # stall_seconds is the watchdog's whole vocabulary; 1 s is the floor that
  # keeps these tests to about a second each.
  defp config, do: %Config{data_dir: "tmp/pipeline_owner_test", stall_seconds: 1}

  defp uid(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  defp camera(id, opts \\ []) do
    struct!(%Camera{id: id, rtsp_url: "rtsp://127.0.0.1:554/x"}, opts)
  end

  defp start_owner(cam, opts \\ []) do
    :persistent_term.put({StubPipeline, cam.id}, self())
    on_exit(fn -> :persistent_term.erase({StubPipeline, cam.id}) end)
    test = self()

    start_supervised!(
      {PipelineOwner,
       opts ++
         [
           camera: cam,
           config: config(),
           pipeline_module: StubPipeline,
           backoff_min_ms: 50,
           backoff_max_ms: 200,
           flush_grace_ms: 20,
           watchdog_interval_ms: 60_000,
           status_fun: fn cam_id, status -> send(test, {:status, cam_id, status}) end
         ]},
      id: {:owner, cam.id}
    )
  end

  # A ring whose only fragment is old enough to be a stall.
  defp stale_ring(id) do
    start_supervised!({RingBuffer, camera_id: id, pre_window_seconds: 5}, id: {:ring, id})
    RingBuffer.put_fragment(id, %Fragment{camera_id: id, seq: 0, pts: 0, data: <<1>>})
    wait_until(fn -> RingBuffer.last_fragment_at(id) != nil end)
    Process.sleep(1_100)
  end

  describe "the pipeline's lifetime" do
    test "is started once, with the owner's initial reason, and monitored" do
      cam = camera(uid("po"))
      owner = start_owner(cam)

      assert_receive {:pipeline_started, pipeline, opts}, 2_000
      assert opts[:camera] == cam
      assert opts[:owner] == owner
      assert opts[:ingest] == :ffmpeg
      # the epoch is minted in band now; nothing here names one
      refute Keyword.has_key?(opts, :epoch)
      assert opts[:initial_reason] == :started

      # a reconnect is not a rebuild: nothing else starts on its own
      refute_receive {:pipeline_started, _pid, _opts}, 300
      assert :sys.get_state(owner).pipeline == pipeline
    end

    @tag :capture_log
    test "a crash is a backoff and a fresh pipeline under :source_lost" do
      cam = camera(uid("pc"))
      start_owner(cam)

      assert_receive {:pipeline_started, pipeline, _opts}, 2_000
      Process.exit(pipeline, :kill)

      assert_receive {:status, _id, :backoff}, 2_000
      assert_receive {:pipeline_started, second, opts}, 2_000
      assert second != pipeline
      assert opts[:initial_reason] == :source_lost
    end

    test "a refresh reaches the running pipeline's detect branch, which survives it" do
      cam = camera(uid("pr"))
      owner = start_owner(cam)

      assert_receive {:pipeline_started, pipeline, _opts}, 2_000

      edited = %Camera{cam | record: %{"person" => %{min_score: 0.9}}}
      :ok = PipelineOwner.refresh(owner, edited, config())

      assert_receive {:pipeline_msg, ^pipeline, {:policy, ^edited, policy}}, 2_000
      assert policy.record == edited.record
      assert :sys.get_state(owner).pipeline == pipeline
    end
  end

  describe "the stream's end" do
    test "a deliberate stop flushes, then announces :camera_stopped" do
      cam = camera(uid("ps"))
      StreamEpochs.subscribe()
      owner = start_owner(cam)
      id = cam.id

      assert_receive {:pipeline_started, pipeline, _opts}, 2_000

      ref = Process.monitor(owner)
      stop_supervised!({:owner, cam.id})
      assert_receive {:DOWN, ^ref, :process, ^owner, _reason}, 5_000

      # the flush is what carries the muxer's held tail into the ring
      assert_receive {:pipeline_msg, ^pipeline, :flush}
      assert_receive {:stream_epoch, ^id, _epoch, :camera_stopped}
    end

    @tag :capture_log
    test "a pipeline crash announces nothing: the rebuild mints its own epoch" do
      cam = camera(uid("pk"))
      StreamEpochs.subscribe()
      start_owner(cam)
      id = cam.id

      assert_receive {:pipeline_started, pipeline, _opts}, 2_000
      Process.exit(pipeline, :kill)

      assert_receive {:pipeline_started, _second, _opts}, 2_000
      refute_received {:stream_epoch, ^id, _epoch, :camera_stopped}
    end
  end

  describe "status" do
    test "follows the source's own report, and :running follows the ring" do
      cam = camera(uid("pt"), ingest: :rtsp)
      owner = start_owner(cam)
      id = cam.id

      assert_receive {:status, ^id, :connecting}, 2_000
      assert_receive {:pipeline_started, _pipeline, _opts}, 2_000

      send(owner, {:stream_backoff, :main, :econnrefused})
      assert_receive {:status, ^id, :backoff}, 2_000

      # reachable again, but nothing has decoded yet
      send(owner, {:stream_connected, :main, []})
      assert_receive {:status, ^id, :connecting}, 2_000

      topic = RingBuffer.topic(id)

      # An init from a session the camera has already left cannot vouch for
      # this one: the epoch in ETS is the reference.
      Phoenix.PubSub.broadcast(Cairn.PubSub, topic, {:init_segment, %{epoch: "01STALE"}})
      Phoenix.PubSub.broadcast(Cairn.PubSub, topic, {:fragment, :whatever})
      refute_receive {:status, ^id, :running}, 300

      epoch = StreamEpochs.new_epoch(id, :started)
      Phoenix.PubSub.broadcast(Cairn.PubSub, topic, {:init_segment, %{epoch: epoch}})
      Phoenix.PubSub.broadcast(Cairn.PubSub, topic, {:fragment, :whatever})
      assert_receive {:status, ^id, :running}, 2_000
    end
  end

  describe "the watchdog" do
    @tag :capture_log
    test "rebuilds when the detect branch goes stale behind a healthy ring" do
      cam = camera(uid("pw"), plugin: {:group, "g"})
      owner = start_owner(cam, watchdog_interval_ms: 50)
      id = cam.id

      assert_receive {:pipeline_started, first, _opts}, 2_000

      # The sink's own reply, stood in for by hand: the detect branch last
      # produced a buffer five stall windows ago, while the ring — which has
      # never held a fragment — is not stale at all.
      send(owner, {:stats, %{last_buffer_at_ms: System.monotonic_time(:millisecond) - 5_000}})

      assert_receive {:status, ^id, :stalled}, 2_000
      assert_receive {:pipeline_started, second, opts}, 2_000
      assert second != first
      assert opts[:initial_reason] == :stall_bounce
    end

    # The same stale stat as the test above, which rebuilds on it: with
    # detection switched off the branch is dropping every frame on purpose, so
    # nothing about the age of its last buffer is news.
    test "a detect branch stale behind a closed detection gate is not a wedge" do
      cam = camera(uid("pd"), plugin: {:group, "g"})
      Cairn.CameraControl.set(cam.id, %{detection_enabled: false})
      owner = start_owner(cam, watchdog_interval_ms: 50)

      assert_receive {:pipeline_started, _first, _opts}, 2_000
      send(owner, {:stats, %{last_buffer_at_ms: System.monotonic_time(:millisecond) - 5_000}})

      refute_receive {:pipeline_started, _pid, _opts}, 500

      # Re-enabling does not rebuild on the age the disable left behind: the
      # branch gets a full stall window to produce its first real buffer.
      Cairn.CameraControl.set(cam.id, %{detection_enabled: true})
      refute_receive {:pipeline_started, _pid, _opts}, 500
    end

    @tag :capture_log
    test "rebuilds a stalled rtsp camera whose source says it is connected" do
      cam = camera(uid("pn"), ingest: :rtsp)
      stale_ring(cam.id)
      owner = start_owner(cam, watchdog_interval_ms: 50)

      assert_receive {:pipeline_started, first, _opts}, 2_000
      send(owner, {:stream_connected, :main, []})

      assert_receive {:pipeline_started, second, opts}, 2_000
      assert second != first
      assert opts[:initial_reason] == :stall_bounce
    end

    @tag :capture_log
    test "a pipeline that never produces a first fragment counts as stalled" do
      cam = camera(uid("pf"), ingest: :rtsp)
      # An empty ring: `last_fragment_at` stays nil, which must not read as
      # healthy forever — the pipeline's own start stands in for it.
      start_supervised!({RingBuffer, camera_id: cam.id, pre_window_seconds: 5},
        id: {:ring, cam.id}
      )

      owner = start_owner(cam, watchdog_interval_ms: 50)

      assert_receive {:pipeline_started, first, _opts}, 2_000
      send(owner, {:stream_connected, :main, []})

      # Not stalled until the pipeline has been up a full stall window.
      refute_receive {:pipeline_started, _pid, _opts}, 300

      assert_receive {:pipeline_started, second, opts}, 2_000
      assert second != first
      assert opts[:initial_reason] == :stall_bounce
    end

    test "leaves a stalled rtsp camera alone while its source is reconnecting" do
      cam = camera(uid("pb"), ingest: :rtsp)
      stale_ring(cam.id)
      owner = start_owner(cam, watchdog_interval_ms: 50)

      assert_receive {:pipeline_started, _first, _opts}, 2_000
      send(owner, {:stream_backoff, :main, :econnrefused})

      # An outage is not a wedge: the in-element reconnect owns it, and a
      # rebuild would cost the detect branch's warm state for nothing.
      refute_receive {:pipeline_started, _pid, _opts}, 500
    end

    @tag :capture_log
    test "bounces a stalled bridge first and rebuilds only past the escalation window" do
      cam = camera(uid("pg"))
      stale_ring(cam.id)

      start_supervised!({StubBridge, {cam.id, self(), true}}, id: {:bridge, cam.id})
      start_owner(cam, watchdog_interval_ms: 50)

      assert_receive {:pipeline_started, first, _opts}, 2_000

      # Rung 1: re-dialling the camera is cheaper than rebuilding the pipeline
      # behind it, so the ladder starts there…
      assert_receive :bounced, 2_000
      refute_receive {:pipeline_started, _pid, _opts}, 100

      # …and only a ring that stays stale past two further ticks, with ffmpeg
      # respawned, is a wedge the bridge cannot clear.
      assert_receive {:pipeline_started, second, opts}, 2_000
      assert second != first
      assert opts[:initial_reason] == :stall_bounce
    end

    @tag :capture_log
    test "a rebuild waits for the old bridge_source registration to clear first" do
      cam = camera(uid("pz"), plugin: {:group, "g"})
      owner = start_owner(cam, watchdog_interval_ms: 50, pipeline_module: StubBridgePipeline)
      id = cam.id

      assert_receive {:pipeline_started, first, _opts}, 2_000

      # Holds the registry's stale-entry window open across the rebuild's
      # stop_pipeline -> start_pipeline: without `await_unregistered/3` there,
      # the fresh pipeline's `{:ok, _} = register(...)` (mirroring the real
      # `BridgeSource`) would hard-match against `first`'s still-resolving
      # entry and crash instead of starting cleanly.
      partition = RegistryHelpers.suspend_registry_reaping()

      Task.start(fn ->
        Process.sleep(200)
        :sys.resume(partition)
      end)

      send(owner, {:stats, %{last_buffer_at_ms: System.monotonic_time(:millisecond) - 5_000}})

      assert_receive {:status, ^id, :stalled}, 2_000
      assert_receive {:pipeline_started, second, opts}, 2_000
      assert second != first
      assert opts[:initial_reason] == :stall_bounce
    end

    test "does not escalate while ffmpeg is still climbing its own backoff" do
      cam = camera(uid("pf"))
      stale_ring(cam.id)

      start_supervised!({StubBridge, {cam.id, self(), false}}, id: {:bridge, cam.id})
      start_owner(cam, watchdog_interval_ms: 50)

      assert_receive {:pipeline_started, _first, _opts}, 2_000
      assert_receive :bounced, 2_000

      refute_receive {:pipeline_started, _pid, _opts}, 500
    end
  end

  defp wait_until(fun, attempts \\ 200) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition never became true")

      true ->
        Process.sleep(10)
        wait_until(fun, attempts - 1)
    end
  end
end
