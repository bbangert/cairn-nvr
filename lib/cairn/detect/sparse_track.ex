defmodule Cairn.Detect.SparseTrack do
  @moduledoc """
  `Membrane.MOTTracker.SparseTrack` wearing cairn's vocabulary: a
  `Membrane.MOTTracker.Core` a camera may name as its `tracker:`, alongside
  `Cairn.Tracker` — never the default.

  The tree is pixel-only and knows no `Cairn.*` name (see its moduledoc and
  `test/membrane_mot_tracker/boundary_test.exs`); cairn's observations are
  normalized `[x, y, w, h]` fractions and its consumers read `%Cairn.Track{}`
  and a fixed set of tagged-object keys. This module is the seam: scale boxes
  in and out of a nominal frame, and translate the tree's plain-map summaries
  into cairn's structs both ways.

  ## The nominal frame

  SparseTrack's thresholds (the IoU's `+1`, the `2000 - bottom_edge`
  pseudo-depth) are pixel-absolute, tuned at MOT17/MOT20's 1080p — a box
  scaled to a different frame size changes every one of those decisions. The
  real geometry is not available on this path: `Cairn.Pipeline.Inference`'s
  `Detections` stream format carries only `observations` and `stream_epoch`
  in its buffer metadata, no frame dimensions. A fixed nominal frame is
  therefore not a fallback but the only scale there is, and `1920x1080`
  keeps every camera — whatever its sensor resolution — behaving like the
  reference the tree is parity-gated against.

  ## Identities

  The tree counts its identities from 1 per instance, which is a number and not
  a name: a track row's primary key is a string, so an integer reaches
  `Cairn.Tracks.insert_batch/1` as a dump error that costs the recorder its
  whole buffer — and two cameras, or one camera either side of a pipeline
  rebuild, would both claim `1` anyway.

  So a `Cairn.ULID` is minted per inner id the first time the tree publishes
  it, exactly as `Cairn.Tracker` mints one for a track it starts, and nothing
  above this module ever sees the counter. The mapping lives in the same per-id
  books as the rest of what the summaries don't carry, and ends where the
  identity does — an adopted one keeps its ULID, which is the whole point of
  the adoption.

  ## The evidence floor

  The batch's context carries the camera's **effective** `min_score`
  (`Cairn.Pipeline.ObservationStamper` resolves the runtime override into it),
  and objects below their label's floor are dropped here rather than passed on.
  That is not what `Cairn.Tracker` does with the same number — it puts them in
  ByteTrack's second association stage, where they may extend a track but not
  mint one — and it is not what the inner core does either, which partitions on
  thresholds of its own. It is what an operator raising the floor at runtime
  asked for: stop reacting to detections below it. The trade is the stage-two
  rescue through an occlusion, given up for one number meaning one thing across
  both cores.

  ## What SparseTrack does not have

  No stationary notion, and no track that was not matched to a real
  detection on the frame it is reported for (its `track/3` doc). So every
  tagged entry here is honestly `stationary: false, observation_kind:
  "detected"` — not placeholders standing in for something this core could
  compute but doesn't.
  """

  @behaviour Membrane.MOTTracker.Core

  alias Membrane.MOTTracker.SparseTrack

  @default_width 1920
  @default_height 1080

  # Bookkeeping the tree's summaries don't carry, held per inner id.
  @typep book_entry :: %{
           object_id: Cairn.ULID.t(),
           camera_id: term(),
           epoch: term(),
           started_at: term(),
           last_seen_at: term(),
           best_score: number()
         }

  @opaque t :: %__MODULE__{
            inner: SparseTrack.t(),
            width: number(),
            height: number(),
            last_observed_at: DateTime.t() | nil,
            book: %{optional(term()) => book_entry()}
          }

  defstruct [:inner, :width, :height, :last_observed_at, book: %{}]

  # The core's own `:max_live` default is no cap at all — the reference has
  # none — and a cairn camera has had one since long before this core was
  # selectable (`Cairn.Tracker` enforces it internally, from the same config
  # key). So the host's default stands in for a caller that names none rather
  # than the tree's, and `Cairn.Pipeline.Camera` passes the camera's own.
  @impl true
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    width = Keyword.get(opts, :width, @default_width)
    height = Keyword.get(opts, :height, @default_height)

    inner_opts =
      opts
      |> Keyword.drop([:width, :height])
      |> Keyword.put_new(:max_live, Cairn.Config.default_max_live_tracks())

    %__MODULE__{inner: SparseTrack.new(inner_opts), width: width, height: height}
  end

  # `context` is required to carry `:camera_id`, `:epoch` and `:observed_at`
  # beyond the generic core's `:at_ms` — cairn's own context always does
  # (`Cairn.Tracker.context/3`), and there is nowhere else this bookkeeping
  # could come from.
  @impl true
  @spec track(t(), [map()], Membrane.MOTTracker.Core.context()) ::
          {t(), [map()], [{atom(), Cairn.Track.t()}]}
  def track(%__MODULE__{} = state, objects, context) do
    scaled =
      objects
      |> admissible(Map.get(context, :min_score))
      |> Enum.map(&scale_in(&1, state))

    {inner, tagged, events} = SparseTrack.track(state.inner, scaled, context)

    book = Enum.reduce(tagged, state.book, &observe(&2, &1, context))
    state = %{state | inner: inner, book: book, last_observed_at: context.observed_at}

    # Both translations read the books before the finals trim them: an identity
    # this frame's live cap evicted is in `tagged` and in an `:ended` event at
    # once, and the two have to name it the same track.
    cairn_tagged = Enum.map(tagged, &tag_out(&1, book, state))
    cairn_events = Enum.map(events, &to_event(&1, book, state))

    {%{state | book: drop_ended(book, events)}, cairn_tagged, cairn_events}
  end

  @impl true
  @spec suspend(t(), pos_integer(), number()) ::
          {t(), [{atom(), Cairn.Track.t()}], Membrane.MOTTracker.Core.suspension()}
  def suspend(%__MODULE__{} = state, max_suspended, cut_ms) do
    {inner, events, report} = SparseTrack.suspend(state.inner, max_suspended, cut_ms)

    # `at` is the last sign of life before the cut, and the host measures the
    # outage gap to it *in wall time* (`Cairn.CameraTracker`'s `report_gap/2`).
    # The tree reports it on the batch clock, which cairn's own core does not —
    # so it is translated here rather than left as the number that would raise
    # in a `DateTime.diff/3` downstream.
    report = %{report | at: state.last_observed_at}

    {%{state | inner: inner, book: drop_ended(state.book, events)},
     Enum.map(events, &to_event(&1, state.book, state)), report}
  end

  @impl true
  @spec expire_suspended(t(), number()) :: {t(), [{atom(), Cairn.Track.t()}]}
  def expire_suspended(%__MODULE__{} = state, at_ms) do
    {inner, events} = SparseTrack.expire_suspended(state.inner, at_ms)

    {%{state | inner: inner, book: drop_ended(state.book, events)},
     Enum.map(events, &to_event(&1, state.book, state))}
  end

  @impl true
  @spec end_all(t(), Cairn.Track.end_reason()) :: {t(), [{atom(), Cairn.Track.t()}]}
  def end_all(%__MODULE__{} = state, reason) do
    {inner, events} = SparseTrack.end_all(state.inner, reason)
    cairn_events = Enum.map(events, &to_event(&1, state.book, state))

    # Nothing survives `end_all` in the tree either — tracked, lost and
    # suspended are all cleared — so the bookkeeping empties with it rather
    # than being walked id by id.
    {%{state | inner: inner, book: %{}}, cairn_events}
  end

  @impl true
  @spec checkpoint_tracks(t()) :: [Cairn.Track.t()]
  def checkpoint_tracks(%__MODULE__{} = state) do
    state.inner
    |> SparseTrack.checkpoint_tracks()
    |> Enum.map(&to_track(&1, state.book, state))
  end

  @impl true
  @spec adoption_window_ms() :: pos_integer()
  def adoption_window_ms, do: SparseTrack.adoption_window_ms()

  # -- the evidence floor -----------------------------------------------------

  # A context with no floor is every caller that builds one by hand, and leaves
  # the batch exactly as the core would have seen it. `Map.get/2` and not a
  # pattern match, for the reason `Cairn.Tracker.partition/2` gives: `context`
  # is a plain map a caller may build without the key.
  defp admissible(objects, nil), do: objects

  defp admissible(objects, floors) do
    Enum.filter(objects, &(&1.score >= floor_for(floors, Map.get(&1, :label))))
  end

  # `Cairn.Tracker`'s resolution, to the fallback: the label's own floor, else
  # the map's `"default"`, else 0.5. Two readings of one number that have to
  # agree, so they are written the same way.
  defp floor_for(floors, label), do: Map.get(floors, label) || Map.get(floors, "default", 0.5)

  # -- units --------------------------------------------------------------

  defp scale_in(%{bbox: [x, y, w, h]} = object, state) do
    %{object | bbox: [x * state.width, y * state.height, w * state.width, h * state.height]}
  end

  defp scale_out([x, y, w, h], state) do
    [x / state.width, y / state.height, w / state.width, h / state.height]
  end

  # -- vocabulary -----------------------------------------------------------

  defp tag_out(summary, book, state) do
    %{
      object_id: entry(book, summary, state).object_id,
      label: summary.label,
      score: summary.score,
      bbox: scale_out(summary.bbox, state),
      stationary: false,
      stale_predicted: false,
      observation_kind: "detected"
    }
  end

  defp to_event({kind, summary}, book, state) do
    {kind, %{to_track(summary, book, state) | end_reason: end_reason(summary)}}
  end

  defp to_track(summary, book, state) do
    entry = entry(book, summary, state)

    %Cairn.Track{
      object_id: entry.object_id,
      camera_id: entry.camera_id,
      label: summary.label,
      score: summary.score,
      best_score: entry.best_score,
      bbox: scale_out(summary.bbox, state),
      source: :host,
      epoch: entry.epoch,
      started_at: entry.started_at,
      last_seen_at: entry.last_seen_at,
      # The same instant as `last_seen_at`, and not by accident: this core
      # reports no track it did not match to a real detection on the frame
      # (its `track/3` doc), so the last sighting *is* the last detection.
      # `Cairn.Tracker` splits the two because it also reports predictions.
      last_detected_at: entry.last_seen_at
    }
  end

  # An id with no bookkeeping cannot happen through the tree's own paths — a
  # summary only leaves it for a track that was reported on some frame, and
  # that frame booked it — but this runs inside the tracker element, where a
  # `KeyError` would take the camera's pipeline down. The fallback is the
  # honest one: what this module knows about the track, and nils for what only
  # a batch could have told it. Its identity is a ULID like any other, minted
  # here and remembered nowhere, so it is unique wherever it lands.
  defp entry(book, summary, state), do: Map.get(book, summary.object_id, unbooked(state, summary))

  defp unbooked(state, summary) do
    %{
      object_id: Cairn.ULID.generate(),
      camera_id: nil,
      epoch: nil,
      started_at: state.last_observed_at,
      last_seen_at: state.last_observed_at,
      best_score: summary.score
    }
  end

  # `:lost` is the tree's own word for a track the buffer ran out on; cairn's
  # is `:unseen` (`Cairn.Track.end_reason`, which has no `:lost` at all).
  # Every other reason a summary carries — `end_all/2`'s own, or the tree's
  # `:stream_reset` — is already one of cairn's, so it passes through.
  defp end_reason(%{reason: :lost}), do: :unseen
  defp end_reason(%{reason: reason}), do: reason
  defp end_reason(_summary), do: nil

  # -- bookkeeping ------------------------------------------------------------

  # The epoch moves with every observation, as `Cairn.Tracker.revive/3` moves
  # an adopted track's: it names the session the track is being seen under, not
  # the one it was minted in, so an identity adopted across a cut stops naming
  # the stream that died. `started_at` is what does not move — the identity did
  # not restart, which is the whole point of having adopted it.
  defp observe(book, %{object_id: id, score: score}, context) do
    Map.update(
      book,
      id,
      %{
        object_id: Cairn.ULID.generate(),
        camera_id: context.camera_id,
        epoch: context.epoch,
        started_at: context.observed_at,
        last_seen_at: context.observed_at,
        best_score: score
      },
      &%{
        &1
        | epoch: context.epoch,
          last_seen_at: context.observed_at,
          best_score: max(&1.best_score, score)
      }
    )
  end

  defp drop_ended(book, events) do
    Enum.reduce(events, book, fn
      {:ended, %{object_id: id}}, book -> Map.delete(book, id)
      _other, book -> book
    end)
  end
end
