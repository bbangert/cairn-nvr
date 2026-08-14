defmodule Cairn.Detect.Dispatch do
  @moduledoc """
  The one hop from the detection producer to a camera's tracker.

  `Cairn.Pipeline.TrackSink` reaches it with what `Membrane.MOTTracker` made of
  the in-VM NIF's frames, resolving `Cairn.Config.policy/2` off the per-frame
  path — at pipeline birth and on refresh — and handing the result through here
  unmodified, so `Cairn.CameraTracker` never calls the config server per frame.

  Plain functions in the caller's process, deliberately not a process of its
  own: a GenServer here would queue every camera's batches behind whichever one
  is in a tracker that is slow to start.
  """

  alias Cairn.CameraTracker
  alias Cairn.Config

  @typedoc """
  One tracked batch, as `Cairn.Pipeline.TrackSink` unpacks it from a
  `Membrane.MOTTracker.Format.Tracks` buffer.

  `observed_at` and `min_score` come from the context the batch was tracked
  with; both are `nil` on the tracker element's own buffers, which answer to no
  batch and carry nothing but the finals of tracks whose adoption window ran
  out.
  """
  @type batch :: %{
          tagged: [map()],
          events: [{atom(), Cairn.Track.t()}],
          snapshot: [Cairn.Track.t()],
          suspension: map() | nil,
          epoch: String.t() | nil,
          observed_at: DateTime.t() | nil,
          min_score: %{optional(String.t()) => float()} | nil
        }

  @doc """
  One tracked batch to `camera`'s tracker, carrying `policy`.

  The tier fork is NOT here: it happens where the branch is built
  (`Cairn.Pipeline.Camera.detect_tail/4`), because a tier-1 camera's
  pipeline contains no tracker element and so nothing that could ever call
  this — a batch that reaches here is tracked by construction.

  `opts[:tracker]` is the producer's injection seam — a process that receives
  the same `{:tracked, …}` cast in place of the camera's own tracker. Absent
  (production) the batch goes to that camera's tracker, started on the first
  batch if it is not running yet.
  """
  @spec forward(Config.Camera.t(), map(), batch(), keyword()) :: :ok
  def forward(%Config.Camera{} = camera, policy, batch, opts \\ []) when is_map(batch) do
    CameraTracker.tracked(Keyword.get(opts, :tracker), camera, policy, batch)
  end
end
