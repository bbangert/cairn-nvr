defmodule Cairn.Camera.Lane do
  @moduledoc """
  A camera's event workers, `:one_for_one` — the `:lane` child of
  `Cairn.Camera`, after `:media`.

  A media restart touches none of them either way: the pipeline reaches these
  workers by resolving their Registry names per batch and casting, holding no
  pid and no monitor, so a worker restarting is invisible to it and the media
  never depends on the lane. `:one_for_one`, so a single worker's crash
  restarts only itself, restoring from its checkpoint, isolated from the other
  workers and from the media. Last, so that on a whole-camera stop this
  subtree goes down FIRST, with its media still standing — see `Cairn.Camera`
  for what these workers need a live ring and an unstopped pipeline for.

  Composition follows the resolved camera's capability tier, the same fork the
  detect branch takes (`Cairn.Pipeline.Camera.detect_tail/4`): tier 1 gets
  `Cairn.PresenceRecorder` and then `Cairn.PresenceAggregator`, every other
  tier — 2, and the `nil` of an unprofiled camera — gets
  `Cairn.CameraTracker`. The tier, not the presence of a detect branch: it is
  what the matrix forks on, and a camera whose branch is off costs one idle
  process, which holds no timer until an event opens.

  The **recorder first**, against the data's direction, and the reason is a
  read that only happens once: `Cairn.PresenceAggregator.init/1` clears its
  predecessor's announced keys, and *deletes those `Cairn.PresenceLedger`
  rows*. The recorder's `adopt_announced/1` reads the same rows to find a
  `presence_started` it was down for — a key the aggregator holds as present
  never announces again, so those rows are the only record of it, and read
  after the aggregator has run they are gone and the whole stay goes
  unrecorded. Reading them first is what records it. Secondary, on the same
  order: with the aggregator started second, the recorder is there to hear its
  cleareds directly, so an event restored from a checkpoint closes on that
  clear rather than on `still_announced/2` dropping its keys as ghosts.

  Nothing is owed the other way: neither `init/1` calls the other, only casts,
  so the order costs no deadlock, and the aggregator's registration is up well
  before the first batch that matters either way. Shutdown, in reverse, stops
  the aggregator first — its cleareds land in a live recorder's mailbox ahead
  of the supervisor's own exit signal, and the recorder finalizes what is still
  open in `terminate/2`. That pairing is the presence lane's alone: the tracker is
  the only worker in its own lane and its `terminate/2` waits on nothing.

  A tier change is therefore not a media change but a change of *this* list,
  which no running supervisor can be edited into: `Cairn.Config.Server` sorts
  such a camera into the diff's `rebuilt` rather than its `changed`, and
  `Cairn.CameraSupervisor` stops and restarts the whole tree for it.
  """

  use Supervisor

  alias Cairn.Config

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    Supervisor.init(children(opts), strategy: :one_for_one)
  end

  # Built from the pair `Cairn.Camera.init/1` resolved for the whole tree, and
  # then held — the workers survive a `:media` replacement, though the clip one
  # of them has open does not (the ring goes with the media; see
  # `Cairn.CameraSupervisor.restart_media/2`). So the copy each holds can be
  # older than the tree around it, and both classes of change that leave these
  # workers standing correct it the same way: a `changed` camera through
  # `restart_media/2` once its new `:media` is up, a `refreshed` one through
  # `refresh_camera/2` — both by way of `refresh_lane/2`. The only window in
  # which a worker holds a stale pair is between the new media starting and
  # that cast landing.
  #
  # It has to be corrected, not merely tolerated: each worker hands its
  # `%Cairn.Config{}` to every `Cairn.EventExtractor` it starts (`config:`), so
  # a clip opened on a stale one is *written* under it. The camera struct is
  # the softer half — `Cairn.PresenceRecorder` re-resolves it at every
  # qualifying transition and `Cairn.CameraTracker` takes it off every batch,
  # and the floors a frame is judged against ride in with the sink's batch
  # either way.
  defp children(opts) do
    cam = Keyword.fetch!(opts, :camera)
    config = Keyword.fetch!(opts, :config)
    args = [camera: cam, config: config]

    case Map.get(Config.policy(config, cam), :tier) do
      1 -> [{Cairn.PresenceRecorder, args}, {Cairn.PresenceAggregator, args}]
      _other -> [{Cairn.CameraTracker, args}]
    end
  end
end
