defmodule Cairn.TrackerSupervisor do
  @moduledoc """
  DynamicSupervisor over `Cairn.CameraTracker` processes — one `:temporary`
  child per camera, started on demand by `Cairn.CameraTracker.ensure/1`.

  Deliberately *not* part of a camera's `:rest_for_one` media tree. A camera's
  ffmpeg or plugin restarting is an ordinary event — a stream reset the tracker
  is written to absorb by suspending its identities — and it must not take the
  tracking state, the open event or the checkpoint's owner-side timers with it.
  """

  use DynamicSupervisor

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
