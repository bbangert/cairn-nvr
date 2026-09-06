defmodule Cairn.TrackerStub do
  @moduledoc """
  Registered under the tracker role and starting its extractor from
  `terminate/2`: that is the only instant a real tracker's own race is
  reachable on demand. A `{:tracked, ...}` cast queued ahead of the reaper's
  stop is drained before it, so the tracker can open an event — and register
  its extractor — while the reaper is inside `GenServer.stop/3`. Driving a
  `Cairn.CameraTracker` to that point needs a whole inference batch and still
  leaves the instant to chance.
  """

  # `:temporary`: the reaper's stop is a normal exit, and a restarted stub
  # would start the same event's extractor a second time at test teardown.
  use GenServer, restart: :temporary

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    {:ok, _} = Cairn.Registry.register(Keyword.fetch!(opts, :camera_id), :camera_tracker)
    {:ok, Map.new(opts)}
  end

  @impl true
  def terminate(_reason, state) do
    {:ok, pid} =
      DynamicSupervisor.start_child(
        Cairn.EventSupervisor,
        {Cairn.EventExtractor, state.extractor_opts}
      )

    # The `active` row lands in the extractor's `handle_continue(:open, ...)`,
    # which a real tracker's start would have waited out too: it holds the pid
    # the supervisor answered with, and the reaper's sweep is the next thing
    # to run either way.
    :sys.get_state(pid)
    send(state.test, {:extractor_started, pid})
    :ok
  end
end

defmodule Cairn.RaisingTrackerStub do
  @moduledoc """
  A lane owner whose `terminate/2` raises — proof that
  `DynamicSupervisor.terminate_child/2` does not read that as a crash to
  restart. `GenServer.stop/3` could not survive this: a target that dies of
  anything else while the call is in flight exits the *caller* with it, and
  the pool then restarts what it takes for an ordinary crash — precisely the
  abnormal-exit race `Cairn.CameraReaper.stop_pid/4` moved off that call to
  close.
  """

  use GenServer, restart: :transient

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    {:ok, _} = Cairn.Registry.register(Keyword.fetch!(opts, :camera_id), :camera_tracker)
    {:ok, Map.new(opts)}
  end

  @impl true
  def terminate(_reason, _state), do: raise("boom")
end

defmodule Cairn.HangingTrackerStub do
  @moduledoc """
  A lane owner whose `terminate/2` never returns: `GenServer.stop/3` times out
  on it with the process still alive and still able to produce. Stands in for
  any terminate that hangs — a held lock, a slow drain — so the reaper's
  kill-on-timeout bound is exercised.
  """

  use GenServer, restart: :temporary

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    {:ok, _} = Cairn.Registry.register(Keyword.fetch!(opts, :camera_id), :camera_tracker)
    {:ok, Map.new(opts)}
  end

  @impl true
  def terminate(_reason, _state), do: Process.sleep(:infinity)
end

defmodule Cairn.RespawningTrackerStub do
  @moduledoc """
  A crash-looping lane owner: every stop leaves a fresh registrant under the
  same id, which is what a deleted camera whose tracker keeps being restarted
  looks like to `Cairn.CameraReaper`'s repeated passes. No number of passes
  clears it, so the last one must fail rather than report the id reaped.
  """

  use GenServer, restart: :temporary

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    {:ok, _} = Cairn.Registry.register(Keyword.fetch!(opts, :camera_id), :camera_tracker)
    {:ok, Map.new(opts)}
  end

  @impl true
  def terminate(_reason, state) do
    # The registry is unique and this process is still alive inside its own
    # terminate, so it drops the key before the replacement takes it —
    # otherwise the successor loses the race and the pass looks clean. Started
    # unlinked, and synchronously: `GenServer.start/3` returns only once the
    # replacement has registered, so the reaper's next read cannot miss it.
    Registry.unregister(Cairn.Registry, {state.camera_id, :camera_tracker})
    {:ok, _pid} = GenServer.start(__MODULE__, camera_id: state.camera_id)
    :ok
  end
end

defmodule Cairn.SlowExtractorStub do
  @moduledoc """
  An extractor whose finalize outlasts `Cairn.CameraReaper`'s `@stop_timeout`,
  standing in for the real cause: `Cairn.ClipRemux` gives ffmpeg up to 60 s
  over the clip before the row is closed.
  """

  use GenServer, restart: :temporary

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    state = Map.new(opts)
    {:ok, _} = Cairn.Registry.register(state.camera_id, {:extractor, state.event_id})
    {:ok, state}
  end

  @impl true
  def handle_cast({:finalize, _event}, state) do
    Process.sleep(state.finalize_ms)
    {:stop, :normal, state}
  end
end
