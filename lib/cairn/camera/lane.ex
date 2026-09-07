defmodule Cairn.Camera.Lane do
  @moduledoc """
  A camera's event workers, `:one_for_one` — the `:lane` child of
  `Cairn.Camera`, ahead of `:media`.

  Ahead, so a media restart touches none of them: the pipeline reaches these
  workers by resolving their Registry names per batch and casting, holding no
  pid and no monitor, so a worker restarting is invisible to it and the media
  never depends on the lane. `:one_for_one`, so a single worker's crash
  restarts only itself, restoring from its checkpoint, isolated from the other
  workers and from the media.

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
  before the first batch either way. Shutdown, in reverse, stops the aggregator
  first — its cleareds land in a live recorder's mailbox ahead of the
  supervisor's own exit signal, and the recorder finalizes what is still open
  in `terminate/2`. That pairing is the presence lane's alone: the tracker is
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
  # then held: `Cairn.CameraSupervisor.restart_media/2` replaces `:media`
  # alone — the workers themselves survive it, though the clip one of them has
  # open does not (the ring goes with the media; see `restart_media/2`) — so
  # after a restart-class change these workers still hold the pre-change
  # struct — and a `changed` camera gets no `{:refresh, _, _}` cast
  # to correct it. The classes are not disjoint: `:min_score` is restart-class
  # and `Cairn.PresenceRecorder.configured_floors/1` reads it off this struct.
  # What makes the stale copy harmless is that nothing consults it without
  # re-resolving first — every qualifying transition runs `resolve_policy/1`,
  # which replaces `camera` and `policy` from the snapshot before the floors
  # are read — and the floors a frame is actually judged against ride in with
  # the sink's batch. A refresh-class edit reaches the lane the ordinary way,
  # through `Cairn.CameraSupervisor.refresh_camera/2`.
  #
  # `Cairn.CameraTracker` holds the same copy under the same rule, and its
  # correction is even more direct: the camera and the floors it judges by
  # arrive with every batch, from the pipeline the replacement rebuilt.
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
