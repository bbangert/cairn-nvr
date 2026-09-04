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
  on it with the process still alive and still able to produce. The real
  shape is a terminate blocked on the config server, which is itself blocked
  on this very pass (`Cairn.Config.Server`'s barrier).
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
