defmodule Cairn.PipelineOwnerTest do
  use ExUnit.Case, async: false

  alias Cairn.Config
  alias Cairn.Config.Camera

  alias Cairn.{
    Event,
    Fragment,
    PipelineOwner,
    PresenceAggregator,
    PresenceEvent,
    RegistryHelpers,
    RingBuffer,
    StreamEpochs
  }

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

  # Matched so the type checker knows the struct: `struct!/2` alone types as
  # `struct()`, and every `%Camera{cam | …}` below would warn.
  defp camera(id, opts \\ []) do
    %Camera{} = struct!(%Camera{id: id, rtsp_url: "rtsp://127.0.0.1:554/x"}, opts)
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
    # Real time past `config/0`'s 1 s stall_seconds floor (the thing under test
    # IS wall-clock staleness); the 100 ms margin is shared with the sleep at
    # the escalation test below — shrink the floor and both go with it.
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

  describe "a zone edit" do
    @drive %{id: "drive", name: "Drive", points: [[0.0, 0.0], [0.4, 0.0], [0.4, 0.4], [0.0, 0.4]]}
    # Far enough from 0 that the aggregator's confirm window never reaches a
    # negative clock, as in `Cairn.PresenceAggregatorTest`.
    @presence_base 1_000_000

    # Two sightings confirm, which is what gives the refresh below a state to
    # clear. Recording off: a confirm would otherwise open a real clip.
    defp announce(camera_id, key) do
      Cairn.CameraControl.put(camera_id, %{recording_enabled: false})

      on_exit(fn ->
        PresenceAggregator.retire(camera_id)
        Cairn.Registry.await_unregistered(camera_id, :presence)
        Cairn.Registry.await_unregistered(camera_id, :presence_recorder)
      end)

      PresenceAggregator.observed(camera_id, @presence_base, %{key => 0.9})
      PresenceAggregator.observed(camera_id, @presence_base + 500, %{key => 0.9})
    end

    @tag :capture_log
    test "with no pipeline to carry it, the owner clears the removed zone itself" do
      cam = camera(uid("zoff"), zones: [@drive])
      id = cam.id
      Event.subscribe()
      owner = start_owner(cam, backoff_min_ms: 5_000, backoff_max_ms: 5_000)

      assert_receive {:pipeline_started, pipeline, _opts}, 2_000
      announce(id, {"drive", "person"})
      assert_receive {:presence_started, %PresenceEvent{camera_id: ^id, zone: "drive"}}, 2_000

      # The backoff window the long backoff above holds open: `state.pipeline`
      # is nil, so nothing downstream of this process exists to be told.
      Process.exit(pipeline, :kill)
      assert_receive {:status, ^id, :backoff}, 2_000

      :ok = PipelineOwner.refresh(owner, %Camera{cam | zones: []}, config())

      assert_receive {:presence_cleared,
                      %PresenceEvent{camera_id: ^id, zone: "drive", label: "person"}},
                     2_000
    end

    test "with the pipeline up, the clear is left to the sink" do
      cam = camera(uid("zon"), zones: [@drive])
      id = cam.id
      Event.subscribe()
      owner = start_owner(cam)

      assert_receive {:pipeline_started, pipeline, _opts}, 2_000
      announce(id, {"drive", "person"})
      assert_receive {:presence_started, %PresenceEvent{camera_id: ^id, zone: "drive"}}, 2_000

      edited = %Camera{cam | zones: []}
      :ok = PipelineOwner.refresh(owner, edited, config())

      # The policy carries the edit to the sink, which owns the clear there —
      # the stub pipeline is not one, so a cleared here would be the owner
      # sending a second.
      assert_receive {:pipeline_msg, ^pipeline, {:policy, ^edited, _policy}}, 2_000
      refute_receive {:presence_cleared, %PresenceEvent{camera_id: ^id}}, 100
    end
  end

  describe "init re-reads the camera" do
    test "a restarted owner builds from the snapshot's refresh-class fields, not its child spec" do
      cam = camera(uid("snap"), plugin: {:group, "g"})
      edited = %Camera{cam | record: %{"person" => %{min_score: 0.9}}}
      # the snapshot carries a restart-class change too, which must NOT win:
      # the siblings above this process were built from the old one
      snap = %Camera{edited | rtsp_url: "rtsp://127.0.0.1:554/moved"}
      camera_id = cam.id

      lookup = fn
        ^camera_id -> {:ok, snap, config()}
        _other -> :error
      end

      start_owner(cam, config_lookup: lookup)

      assert_receive {:pipeline_started, _pipeline, opts}, 2_000
      assert opts[:camera].record == edited.record
      assert opts[:camera].rtsp_url == cam.rtsp_url
      assert opts[:detect][:policy].record == edited.record
    end

    test "an owner with no snapshot builds from its child spec" do
      cam = camera(uid("nosnap"))
      start_owner(cam, config_lookup: fn _id -> :error end)

      assert_receive {:pipeline_started, _pipeline, opts}, 2_000
      assert opts[:camera] == cam
    end

    @tag :capture_log
    test "a ring crash rebuilds the owner with the refreshed camera" do
      # `ingest: :rtsp` keeps the bridge out of the tree; the probe task runs
      # ffprobe against the fake url and fails, which is what a probe does here.
      cam = camera(uid("ring"), ingest: :rtsp, plugin: {:group, "g"})
      key = {__MODULE__, :lookup, cam.id}
      on_exit(fn -> :persistent_term.erase(key) end)

      :persistent_term.put({StubPipeline, cam.id}, self())
      on_exit(fn -> :persistent_term.erase({StubPipeline, cam.id}) end)

      start_supervised!(
        {Cairn.Camera,
         camera: cam,
         config: config(),
         owner_opts: [
           pipeline_module: StubPipeline,
           config_lookup: fn _id -> :persistent_term.get(key, :error) end,
           backoff_min_ms: 50,
           backoff_max_ms: 200,
           flush_grace_ms: 20,
           watchdog_interval_ms: 60_000,
           status_fun: fn _id, _status -> :ok end
         ]},
        id: {:tree, cam.id}
      )

      assert_receive {:pipeline_started, first, opts}, 5_000
      assert opts[:camera] == cam

      owner = Cairn.Registry.whereis(cam.id, :pipeline)
      edited = %Camera{cam | record: %{"person" => %{min_score: 0.9}}}
      :ok = PipelineOwner.refresh(owner, edited, config())
      assert_receive {:pipeline_msg, ^first, {:policy, ^edited, _policy}}, 2_000

      # What the server publishes for that same reload. The moved rtsp_url is
      # restart-class: the ring and bridge above this process were built from
      # the old one, so opts has to win it back.
      moved = %Camera{edited | rtsp_url: "rtsp://127.0.0.1:554/moved"}
      :persistent_term.put(key, {:ok, moved, config()})

      # :rest_for_one rebuilds the owner from the STORED child spec, which
      # still carries the pre-refresh struct
      cam.id |> Cairn.Registry.whereis(:ring_buffer) |> Process.exit(:kill)

      assert_receive {:pipeline_started, second, opts2}, 5_000
      assert second != first
      assert opts2[:camera].record == edited.record
      assert opts2[:camera].rtsp_url == cam.rtsp_url
    end

    # What is pinned: the reload publishes its snapshot BEFORE calling
    # apply_diff, and an owner born inside that call sees it. The owners are
    # started the way `Cairn.CameraSupervisor.apply_diff/2` starts them —
    # supervisor-free, so `init/1` runs inside the server process while the
    # reload is still in `handle_call`. The deadlock this arrangement would
    # cause has no time-box here: the default `config_lookup` addresses the
    # application's own named server, which is idle in test, so a call from
    # `init/1` would return rather than hang.
    test "owners started from inside a reload build from the fleet it published" do
      dir =
        Path.join(System.tmp_dir!(), "cairn_owner_reload_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      path = Path.join(dir, "config.yml")
      name = :"reload_test_#{System.unique_integer([:positive])}"
      on_exit(fn -> :persistent_term.erase(Config.Server.snapshot_key(name)) end)

      ids = Enum.map(1..3, fn _ -> uid("reload") end)
      test_pid = self()

      Enum.each(ids, fn id ->
        :persistent_term.put({StubPipeline, id}, test_pid)
        on_exit(fn -> :persistent_term.erase({StubPipeline, id}) end)
      end)

      cam_a = "  - id: cam_a\n    rtsp_url: rtsp://h/1\n"

      write_config = fn cameras ->
        File.write!(path, "data_dir: #{Path.join(dir, "data")}\ncameras:\n" <> cameras)
      end

      write_config.(cam_a)

      # The camera in opts is BARE: `record` exists only in the YAML, so an
      # owner that skipped the snapshot could not produce it.
      apply_diff = fn _diff, _config ->
        Enum.each(ids, fn id ->
          {:ok, pid} =
            PipelineOwner.start_link(
              camera: camera(id),
              config: config(),
              config_lookup: &Config.Server.snapshot_camera(&1, name),
              pipeline_module: StubPipeline,
              backoff_min_ms: 50,
              backoff_max_ms: 200,
              flush_grace_ms: 20,
              watchdog_interval_ms: 60_000,
              status_fun: fn _id, _status -> :ok end
            )

          send(test_pid, {:owner_started, pid})
        end)
      end

      server =
        start_supervised!(
          {Config.Server,
           path: path, name: name, apply_native: fn _config -> :ok end, apply_diff: apply_diff},
          id: :reload_owner_server
        )

      write_config.(
        cam_a <>
          Enum.map_join(ids, fn id ->
            "  - id: #{id}\n    rtsp_url: rtsp://h/#{id}\n    record:\n      person: 0.9\n"
          end)
      )

      assert {:ok, %{added: added}, _warnings} = Config.Server.reload(server)
      assert Enum.sort(added) == Enum.sort(ids)

      # Registered from the test process: a failure below must not leak an
      # owner past the `{StubPipeline, id}` erase above. A stop, so the
      # owner's terminate takes its stub pipeline with it; caught, because
      # these are linked to the server the harness tears down in parallel and
      # stopping an already-dying pid exits the caller.
      Enum.each(ids, fn _ ->
        assert_receive {:owner_started, pid}

        on_exit(fn ->
          try do
            GenServer.stop(pid)
          catch
            :exit, _already_down -> :ok
          end
        end)
      end)

      Enum.each(ids, fn _ ->
        assert_receive {:pipeline_started, _pipeline, opts}, 2_000
        assert opts[:camera].record == %{"person" => %{min_score: 0.9}}
        assert opts[:camera].id in ids
      end)
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
      assert_receive {:stream_epoch, ^id, :main, _epoch, :camera_stopped}
    end

    test "a dual-stream camera's stop is announced once per role" do
      cam = camera(uid("pd"), substream_url: "rtsp://127.0.0.1:554/sub")
      StreamEpochs.subscribe()
      owner = start_owner(cam)
      id = cam.id

      assert_receive {:pipeline_started, _pipeline, _opts}, 2_000

      ref = Process.monitor(owner)
      stop_supervised!({:owner, cam.id})
      assert_receive {:DOWN, ^ref, :process, ^owner, _reason}, 5_000

      # A stop takes both ingests, and a consumer following one role learns
      # nothing from the other's announcement — so each stream gets its own.
      assert_receive {:stream_epoch, ^id, :main, main, :camera_stopped}
      assert_receive {:stream_epoch, ^id, :sub, sub, :camera_stopped}
      assert main != sub
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
      refute_received {:stream_epoch, ^id, :main, _epoch, :camera_stopped}
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
      Cairn.CameraControl.put(cam.id, %{detection_enabled: false})
      owner = start_owner(cam, watchdog_interval_ms: 50)

      assert_receive {:pipeline_started, _first, _opts}, 2_000
      send(owner, {:stats, %{last_buffer_at_ms: System.monotonic_time(:millisecond) - 5_000}})

      refute_receive {:pipeline_started, _pid, _opts}, 500

      # Re-enabling does not rebuild on the age the disable left behind: the
      # branch gets a full stall window to produce its first real buffer.
      Cairn.CameraControl.put(cam.id, %{detection_enabled: true})
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

  # The dual-stream half of the ladder. The detect branch hangs off the sub
  # stream, so its silence has one more innocent explanation than a
  # single-stream camera's — and the rebuild it would escalate to is
  # pipeline-wide (D3), taking a main stream that is recording perfectly well.
  # Ticks are driven rather than waited out: what these assert is the
  # decision, and the decision is one `handle_info(:watchdog, …)`.
  describe "the watchdog on a dual-stream camera" do
    defp dual(prefix),
      do:
        camera(uid(prefix),
          ingest: :rtsp,
          plugin: {:group, "g"},
          substream_url: "rtsp://127.0.0.1:554/sub"
        )

    defp wedge(owner) do
      send(owner, {:stats, %{last_buffer_at_ms: System.monotonic_time(:millisecond) - 5_000}})
      send(owner, :watchdog)
    end

    # The main stream is recording perfectly well throughout — which is both
    # the premise of every test here (only the sub is in trouble) and what
    # keeps the ring signal out of the way of the detect one.
    defp recording(cam) do
      start_supervised!({RingBuffer, camera_id: cam.id, pre_window_seconds: 5},
        id: {:ring, cam.id}
      )

      fragment(cam)
    end

    defp fragment(cam) do
      RingBuffer.put_fragment(cam.id, %Fragment{camera_id: cam.id, seq: 0, pts: 0, data: <<1>>})
      wait_until(fn -> RingBuffer.last_fragment_at(cam.id) != nil end)
    end

    test "waits for the substream to connect before believing the detect signal" do
      cam = dual("dn")
      recording(cam)
      owner = start_owner(cam)
      assert_receive {:pipeline_started, _first, _opts}, 2_000

      # The sub has never answered, so nothing has ever fed the branch and
      # the age of its last buffer is not evidence of anything.
      wedge(owner)
      refute_receive {:pipeline_started, _pid, _opts}, 500
    end

    test "leaves a sub in backoff to its own reconnect ladder" do
      cam = dual("db")
      recording(cam)
      owner = start_owner(cam)
      id = cam.id
      assert_receive {:pipeline_started, _first, _opts}, 2_000

      send(owner, {:stream_connected, :sub, []})
      send(owner, {:stream_backoff, :sub, :econnrefused})

      wedge(owner)
      refute_receive {:pipeline_started, _pid, _opts}, 500

      # …and the camera never read as anything but healthy: the sub is not
      # what the lifecycle status is about, and a rebuild that never
      # happened is a main stream still recording.
      refute_received {:status, ^id, :backoff}
      refute_received {:status, ^id, :stalled}
    end

    @tag :capture_log
    test "rebuilds a substream that is connected and feeding nothing" do
      cam = dual("dw")
      recording(cam)
      owner = start_owner(cam)
      id = cam.id
      assert_receive {:pipeline_started, first, _opts}, 2_000

      send(owner, {:stream_connected, :sub, []})
      wedge(owner)

      assert_receive {:status, ^id, :stalled}, 2_000
      assert_receive {:pipeline_started, second, opts}, 2_000
      assert second != first

      # Both roles' first epoch is minted under it: the rebuild took both
      # streams, so `:stall_bounce` is as true of the sub's as of main's.
      assert opts[:initial_reason] == :stall_bounce
    end

    @tag :capture_log
    test "a sub that reconnects gets a full stall window before it is judged" do
      cam = dual("dr")
      recording(cam)
      owner = start_owner(cam)
      assert_receive {:pipeline_started, first, _opts}, 2_000

      # The outage, then the recovery, then a tick with the stamp the outage
      # left behind — which is as old as the outage and says nothing about
      # the session that just started.
      send(owner, {:stream_backoff, :sub, :econnrefused})
      wedge(owner)
      send(owner, {:stream_connected, :sub, []})
      send(owner, :watchdog)

      refute_receive {:pipeline_started, _pid, _opts}, 500

      # It is still the escalation of last resort, not a waiver: a branch
      # that stays silent past the window is a wedge either way.
      Process.sleep(1_100)
      fragment(cam)
      wedge(owner)
      assert_receive {:pipeline_started, second, _opts}, 2_000
      assert second != first
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
