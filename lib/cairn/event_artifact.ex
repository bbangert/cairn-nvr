defmodule Cairn.EventArtifact do
  @moduledoc """
  One of an event's media artifacts becoming fetchable — or failing to.

  Broadcast on the same `"events"` PubSub topic as `Cairn.Event` and
  `Cairn.Track` as `{:event_clip_ready | :event_clip_failed |
  :event_snapshot_ready | :event_snapshot_failed, %Cairn.EventArtifact{}}`.

  `event_ended` says one thing only: the detection window closed. At that
  moment the clip is still being remuxed and the snapshot has not been taken,
  so nothing on disk is fetchable yet. These kinds are the signal that it is:

    * `:event_clip_ready` — the clip is closed, remuxed and indexed. `bytes`
      is the final, **post-remux** size.
    * `:event_snapshot_ready` — the jpg exists *and* is recorded on the event
      row, so `snapshot_url` resolves. `bytes` is its size.
    * `:event_clip_failed` / `:event_snapshot_failed` — that artifact is not
      coming for this event. Nothing retries it.

  Exactly one of `_ready` / `_failed` is emitted per attempt: a `_ready`
  carries `path` and `bytes` with no `reason`, a `_failed` carries a `reason`
  with neither — the struct's two `broadcast/2` clauses are what enforce it.

  An event whose recording crashed emits neither: it never reaches the
  extractor's finalize path, and is announced by `event_ended` with
  `status: :partial` instead.

  `reason` is drawn from a closed set, never built from ffmpeg or plugin
  output — a reason is a thing consumers branch on, and minting atoms from
  foreign text would be an atom-table leak besides.
  """

  # Deliberately not `@derive Jason.Encoder`, unlike its siblings: `path` is an
  # on-disk path and must never reach the wire. `CairnWeb.Api.EventJSON`
  # shapes it into `clip_url`/`snapshot_url` instead.
  @enforce_keys [:event_id, :camera_id]
  defstruct [:event_id, :camera_id, :path, :bytes, :reason]

  @type t :: %__MODULE__{
          event_id: String.t(),
          camera_id: String.t(),
          path: Path.t() | nil,
          bytes: non_neg_integer() | nil,
          reason: reason() | nil
        }

  @typedoc """
  Why an artifact will not arrive:

    * `:not_found` — the event row was gone by the time the artifact landed
      (deleted by retention, or never inserted).
    * `:index_write_failed` — the row exists but the update was rejected.
    * `:no_output` — ffmpeg wrote no usable file.
    * `:exception` — the snapshot task raised; see the log for the message.
  """
  @type reason :: :not_found | :index_write_failed | :no_output | :exception

  @type kind ::
          :event_clip_ready | :event_clip_failed | :event_snapshot_ready | :event_snapshot_failed

  @ready_kinds [:event_clip_ready, :event_snapshot_ready]
  @failed_kinds [:event_clip_failed, :event_snapshot_failed]

  # `local_broadcast`, as for `Cairn.Track`: an artifact is a file on *this*
  # node's disk, so handing the message to the cluster adapter buys nothing.
  @spec broadcast(kind(), t()) :: :ok
  def broadcast(kind, %__MODULE__{reason: nil} = artifact) when kind in @ready_kinds do
    do_broadcast(kind, artifact)
  end

  def broadcast(kind, %__MODULE__{path: nil, bytes: nil} = artifact) when kind in @failed_kinds do
    do_broadcast(kind, artifact)
  end

  defp do_broadcast(kind, artifact) do
    Phoenix.PubSub.local_broadcast(Cairn.PubSub, Cairn.Event.topic(), {kind, artifact})
  end
end
