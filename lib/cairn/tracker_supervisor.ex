defmodule Cairn.TrackerSupervisor do
  @moduledoc """
  The tracking subtree: a `DynamicSupervisor` pool of `Cairn.CameraTracker`
  processes — `Cairn.TrackerSupervisor.Pool`, one `:transient` child per
  camera, started on demand by `Cairn.CameraTracker.ensure/1` and restarted
  after a crash so its checkpoint restore does not wait for the camera's next
  observation (see the tracker's moduledoc) — followed by the sweep that
  restores the trackers of cameras whose `Cairn.EventCheckpoint` rows outlived
  them.

  `:rest_for_one` is what makes the second child worth having. One tracker
  crash-looping past the pool's restart intensity takes the pool down and every
  other camera's tracker with it, while the checkpoint rows — owned elsewhere —
  survive. The cascade restarts the pool *and* re-runs the sweep, so those rows
  get their `:host_restart` finals then and there instead of when each camera's
  next observation happens to arrive.

  Deliberately *not* part of a camera's `:rest_for_one` media tree. A camera's
  ffmpeg or plugin restarting is an ordinary event — a stream reset the tracker
  is written to absorb by suspending its identities — and it must not take the
  tracking state, the open event or the checkpoint's owner-side timers with it.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {DynamicSupervisor, name: Cairn.TrackerSupervisor.Pool, strategy: :one_for_one},
      # `:transient`, not the `Task` default `:temporary`: a temporary child is
      # deleted from the supervisor's child list as soon as it exits, and a
      # child that is gone from the list is not part of any later cascade — the
      # sweep would run once at boot, against an empty table, and never again.
      # A transient child that exited normally stays in the list and is
      # restarted when the pool above it goes down, which is the only moment
      # the sweep has anything to find.
      Supervisor.child_spec({Task, &Cairn.CameraTracker.restore_checkpointed/0},
        id: :restore_checkpointed,
        restart: :transient
      )
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
