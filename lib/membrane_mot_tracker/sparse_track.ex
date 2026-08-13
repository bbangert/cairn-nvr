defmodule Membrane.MOTTracker.SparseTrack do
  @moduledoc """
  SparseTrack as a `Membrane.MOTTracker.Core`: ByteTrack's two-stage
  association, cascaded over pseudo-depth.

  ByteTrack associates twice — once against the confident detections, then a
  second time against the leftovers a detector was unsure about, which is what
  rescues a track through an occlusion. SparseTrack adds the observation that a
  monocular scene has a depth order and a detector's boxes encode it: the lower
  a box's bottom edge sits, the nearer the object. Sorting both sides by that
  pseudo-depth and associating **level by level, near to far** keeps a distant
  track from stealing a near detection that merely overlaps it in the image
  plane, which is the failure mode that dense crowds are made of. What a level
  fails to match carries into the next one, so the split costs nothing except
  where the two sides disagree on how many levels they have — see `cascade`.

  Ported from `tools/mot-bench/vendor/sparsetrack/` (hustvl/SparseTrack @
  499844f, MIT) as patched by `tools/mot-bench/vendor-patches/sparsetrack.patch`
  — the detections-only `(N, 5)` interface, appearance and GMC absent. Global
  motion compensation is not merely unconfigured here: the patch's reference
  runs it with an identity warp, which is arithmetically nothing, and the
  authors' own MOT20 protocol disables it too.

  ## Units are pixels

  Not frame-normalized boxes, and not by convention — by arithmetic. The
  overlap test carries `cython_bbox`'s `+1`-pixel convention, and the
  pseudo-depth of a box is `2000 - bottom_edge`, an absolute pixel constant. A
  normalized box would make every pair overlap almost perfectly and every box
  sit at the same depth. A host whose detections are normalized has to scale
  them by the frame before they get here.

  ## What is parity-gated, and what cannot be

  `c:Membrane.MOTTracker.Core.track/3` is gated to an **exact** match against
  the reference — same identities, same boxes, byte for byte through the MOT
  prediction lines (`test/membrane_mot_tracker/sparse_track_parity_test.exs`).

  Suspension is not, and could not be: the reference has no notion of a stream
  epoch, an adoption window, or a track that outlives the frames. `suspend/3`,
  `expire_suspended/2`, `end_all/2` and the adoption of a suspended identity
  are this port's own, shaped after the host tracker they sit beside, and they
  are **parity-exempt** — the reference never reaches them, so the fixture
  cannot judge them. A run that never cuts suspends nothing, so every one of
  them is a no-op there — `track/3` settles lapsed suspensions on its way in
  and finds none — which is what keeps the gate meaningful.

  `:max_live` is this port's own on the same terms, and inside `track/3`: the
  reference has no ceiling on how many identities a frame may leave behind, so
  the option defaults to `:infinity` and a parity run trims nothing.

  ## Faithfulness notes

  Two of the reference's behaviours look like defects and are ported anyway,
  because parity is the point:

  * A track removed by the lost-buffer expiry stays in the lost list for one
    more frame, so it can be re-activated after it was removed. The subtraction
    that would drop it runs against the *previous* frame's removed set. The
    revival is kept, and this port dates its own final by it rather than by the
    expiry: `:ended` goes out on the frame the subtraction drops the track, so
    nothing this core can still re-activate has been ended, and nothing that
    was ended can come back.
  * An identity removed once can never be lost again — it is subtracted out of
    the lost list the moment it lands there. The reference keeps every removed
    id forever to do that, which an element that runs for weeks cannot; this
    port keeps only the identities (never the tracks) and only while a tracked,
    lost or suspended entry still carries the id (`tombstones/5`). The
    subtraction is the set's one reader and every id it can test comes from
    those three pools, so the pruning is invisible to it — and ids are minted
    monotonically, so a pruned one is never handed out again.

  ## Frames, not milliseconds

  The lost-track buffer is counted in frames, and one `track/3` call is one
  frame — the same convention the Kalman filter's velocities are learned in.
  `context.at_ms` is read for the summaries and for the suspension bounds, and
  is not what any association decision is measured against.
  """

  @behaviour Membrane.MOTTracker.Core

  alias Membrane.MOTTracker.SparseTrack.{Assignment, Kalman}

  # SparseTrack's published MOT17 track config (`mot17_track_cfg.py`), which is
  # also what `tools/mot-bench/bytetrack_sweep.py` sweeps the reference with.
  @track_thresh 0.6
  @track_buffer 30
  @match_thresh 0.75
  @confirm_thresh 0.8
  @depth_levels 1
  @depth_levels_low 3
  @low_thresh 0.1
  @second_thresh 0.3
  @frame_rate 30

  # The horizon the reference measures pseudo-depth back from. The subtraction
  # is what matters: it puts the nearest box (the lowest bottom edge in the
  # frame) at the *smallest* depth, so the cascade's first level is the near
  # one. The constant's value does not, since everything downstream is a
  # comparison or a difference and 2000 is a whole number, which `floor` and
  # `ceil` pass through. It is 2000 because the reference says 2000.
  @depth_horizon 2000

  # Suspension bounds, from the host tracker this core sits beside: the same
  # window and the same overlap an adoption is granted on. The window is a
  # constant and not an option, because the element arms its sweep timer from
  # `adoption_window_ms/0` — a per-instance window would be one the timer never
  # hears about.
  @adoption_window_ms 60_000
  @adoption_iou 0.4

  @typedoc "A tracker state. Opaque."
  @opaque t :: %__MODULE__{}

  defstruct tracked: [],
            lost: [],
            removed_ids: MapSet.new(),
            suspended: [],
            frame_id: 0,
            next_id: 0,
            at_ms: nil,
            track_thresh: @track_thresh,
            det_thresh: @track_thresh + 0.05,
            low_thresh: @low_thresh,
            match_thresh: @match_thresh,
            second_thresh: @second_thresh,
            confirm_thresh: @confirm_thresh,
            depth_levels: @depth_levels,
            depth_levels_low: @depth_levels_low,
            max_time_lost: @track_buffer,
            mot20: false,
            adoption_iou: @adoption_iou,
            max_live: :infinity

  @doc """
  A tracker configured by the reference's own knobs, at its published MOT17
  defaults.

    * `:track_thresh` (#{@track_thresh}) — the confidence that splits the two
      association stages. Strictly above is stage one; strictly between
      `:low_thresh` and this is stage two; a score exactly equal to it is in
      neither, which is the reference's own boundary and not a slip.
    * `:det_thresh` (`:track_thresh + 0.05`) — the floor a leftover detection
      must clear to mint a track. The reference derives it from the annotation
      file's name; there is no such file here, so it is an option with the
      reference's non-half-split value.
    * `:low_thresh` (#{@low_thresh}) — the floor of stage two.
    * `:track_buffer` (#{@track_buffer}) and `:frame_rate` (#{@frame_rate}) —
      how many frames a lost track stays adoptable, as
      `frame_rate / 30 * track_buffer` truncated.
    * `:match_thresh` (#{@match_thresh}) / `:second_thresh` (#{@second_thresh})
      / `:confirm_thresh` (#{@confirm_thresh}) — the cost limits of the three
      associations: stage one, stage two, and the pass that confirms or
      discards a track minted last frame.
    * `:depth_levels` (#{@depth_levels}) / `:depth_levels_low`
      (#{@depth_levels_low}) — how many pseudo-depth sublevels each stage
      cascades over. One level is no cascade at all, which is what the
      published MOT17 config asks of stage one.
    * `:mot20` (false) — the dense-crowd switch: it turns *off* the
      score-weighted overlap cost, because in a crowd a confident box is not a
      better match, just a bigger one.
    * `:adoption_iou` (#{@adoption_iou}) — how much a new detection must
      overlap a suspended identity to take it back. This port's, not the
      reference's (see the moduledoc). How long it stays adoptable is not an
      option beside it: see `adoption_window_ms/0`.
    * `:max_live` (`:infinity`) — a ceiling on the identities one frame may
      leave behind, tracked and lost together (see `track/3`). The reference
      has none, and neither does a run at this default, which is what keeps
      the parity gate judging the reference's own arithmetic; a host that
      caps its trackers passes its own cap.
  """
  @impl true
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    track_thresh = Keyword.get(opts, :track_thresh, @track_thresh)
    frame_rate = Keyword.get(opts, :frame_rate, @frame_rate)
    track_buffer = Keyword.get(opts, :track_buffer, @track_buffer)

    %__MODULE__{
      track_thresh: track_thresh,
      det_thresh: Keyword.get(opts, :det_thresh, track_thresh + 0.05),
      low_thresh: Keyword.get(opts, :low_thresh, @low_thresh),
      match_thresh: Keyword.get(opts, :match_thresh, @match_thresh),
      second_thresh: Keyword.get(opts, :second_thresh, @second_thresh),
      confirm_thresh: Keyword.get(opts, :confirm_thresh, @confirm_thresh),
      depth_levels: levels!(opts, :depth_levels, @depth_levels),
      depth_levels_low: levels!(opts, :depth_levels_low, @depth_levels_low),
      max_time_lost: trunc(frame_rate / 30.0 * track_buffer),
      mot20: Keyword.get(opts, :mot20, false),
      adoption_iou: Keyword.get(opts, :adoption_iou, @adoption_iou),
      max_live: Keyword.get(opts, :max_live, :infinity)
    }
  end

  # `depth_masks/2` divides the depth span by the level count and sweeps the
  # bounds forward from the near edge, so anything but a positive integer is
  # arithmetic rather than a configuration: zero divides by zero, and a
  # negative step yields an empty range the mask builder takes the head of.
  defp levels!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      levels when is_integer(levels) and levels > 0 ->
        levels

      other ->
        raise ArgumentError,
              "#{inspect(key)} must be a positive integer, got #{inspect(other)}"
    end
  end

  @doc """
  One frame.

  `objects` are maps carrying at least `:bbox` (pixel `[x, y, w, h]`) and
  `:score`; anything else on them is ignored, and `:label` is carried onto the
  identity if present. The tracker is class-agnostic, as the reference is: two
  boxes of different labels compete for the same identity.

  The tagged list is **not** the input list. What comes back is the frame's
  confirmed tracks in the reference's own output order, each box the Kalman
  posterior rather than the detection that produced it — which is what the
  reference emits and what the parity fixture compares. Every one of them was
  matched to a real detection on this frame, so no box here is an extrapolation.

  A suspension whose adoption window has run out by this batch's `at_ms` is
  settled first, and its final leads the returned events: the batch that
  arrives after a window closed is what closes it, rather than a stream that
  keeps flapping restarting the element's sweep timer and postponing the final
  indefinitely.

  What the frame leaves behind is trimmed to `:max_live` last of all, and the
  evictions' finals trail the events: a frame that mints more identities than
  the host allows has still tracked them, and the trim is what the host is owed
  afterwards rather than something the association was told about.
  """
  @impl true
  @spec track(t(), [map()], Membrane.MOTTracker.Core.context()) :: {t(), [map()], [tuple()]}
  def track(%__MODULE__{} = state, objects, context) do
    at_ms = Map.get(context, :at_ms)
    {state, lapsed} = expire_lapsed(state, at_ms)
    frame_id = state.frame_id + 1

    {high, low} = split_by_score(objects, state)

    # Tracks minted last frame have not been confirmed by a second sighting, so
    # they are held out of both stages and given the leftovers at the end.
    {unconfirmed, confirmed} = Enum.split_with(state.tracked, &(not &1.activated?))

    pool =
      confirmed
      |> joint(state.lost)
      |> Enum.map(&predict/1)

    first = %{
      levels: state.depth_levels,
      thresh: state.match_thresh,
      fuse?: not state.mot20,
      frame_id: frame_id
    }

    # Stage two never weights the cost by the score: every detection in it is
    # one the detector was unsure about, so there is nothing to rank them by.
    second = %{first | levels: state.depth_levels_low, thresh: state.second_thresh, fuse?: false}

    {activated, refind, u_track, u_high} = cascade(high, pool, {[], []}, first)

    {activated, refind, u_second, _u_low} =
      cascade(low, Enum.filter(u_track, &(&1.state == :tracked)), {activated, refind}, second)

    marked_lost = for track <- u_second, track.state != :lost, do: %{track | state: :lost}

    {confirmations, removed_now, u_high} =
      confirm(unconfirmed, u_high, frame_id, state)

    {minted, next_id, suspended} = mint(u_high, frame_id, at_ms, state)

    activated = activated ++ confirmations ++ minted

    settled = activated ++ refind ++ marked_lost ++ removed_now

    # The already-removed are skipped rather than removed twice. The reference
    # does remove them twice — a track it expired last frame is still in the
    # lost list this frame (see the moduledoc) and its second append lands in a
    # set, where it is invisible. Here a second marking would put the copy the
    # expiry froze back into `changed` ahead of the pool's predicted one, and
    # stall the box of a track that is still adoptable.
    expired =
      for track <- state.lost,
          track = resolve(track, settled ++ pool),
          track.state != :removed,
          frame_id - track.frame_id > state.max_time_lost,
          do: %{track | state: :removed}

    # The prediction is state, not a scratch value: the reference predicts its
    # pool in place, so a lost track that goes on unmatched keeps advancing
    # frame after frame rather than resuming from where it was lost. `pool`
    # comes last, so every track falls back to its predicted self and anything
    # this frame did to it wins.
    changed = settled ++ expired ++ pool

    tracked =
      state.tracked
      |> Enum.map(&resolve(&1, changed))
      |> Enum.filter(&(&1.state == :tracked))
      |> joint(activated)
      |> joint(refind)

    live_ids = MapSet.new(tracked, & &1.id)

    # The subtraction against the *previous* frame's removed set is where an
    # identity actually leaves this core, one frame after the expiry marked it
    # (see the moduledoc) — and where a track re-lost after a revival goes,
    # since a removed id may not sit in the lost list at all. So it is also
    # where the final belongs: what departs here is what nothing can revive.
    {lost, departed} =
      state.lost
      |> Enum.map(&resolve(&1, changed))
      |> Enum.reject(&(&1.id in live_ids))
      |> Kernel.++(marked_lost)
      |> Enum.split_with(&(&1.id not in state.removed_ids))

    output = Enum.filter(tracked, & &1.activated?)
    events = lifecycle(output, removed_now ++ departed, at_ms)

    state = %{
      state
      | tracked: Enum.map(tracked, &remember/1),
        lost: lost,
        removed_ids:
          tombstones(state.removed_ids, removed_now ++ expired, tracked, lost, suspended),
        suspended: suspended,
        frame_id: frame_id,
        next_id: next_id,
        at_ms: at_ms
    }

    {state, evicted} = trim_live(state)

    {state, Enum.map(output, &summary(&1, at_ms)), lapsed ++ events ++ evicted}
  end

  # The tombstones worth carrying into the next frame. Their one reader is the
  # subtraction above, which tests the ids of `state.lost` and of the tracks
  # this frame marked lost — both drawn from the frame's own `tracked` and
  # `lost` — and an adoption can hand a suspension's id back into `tracked`
  # frames later, so a suspended id keeps its tombstone too. An id in none of
  # the three is unreachable: nothing can put it back in a pool the reader
  # draws from, and `mint/4` never reissues it.
  #
  # Without this the set is the reference's: every id ever removed, forever,
  # which is fine for a finite MOT sequence and unbounded for an element that
  # runs for weeks.
  defp tombstones(removed_ids, removed, tracked, lost, suspended) do
    held = MapSet.new(Enum.concat([tracked, lost, suspended]), & &1.id)

    removed_ids
    |> MapSet.union(MapSet.new(removed, & &1.id))
    |> MapSet.intersection(held)
  end

  # The live cap. `lost` counts against it beside `tracked`: a lost track is
  # still an identity this core may re-emerge, and one frame's detections times
  # the lost buffer is exactly the growth the cap exists to bound.
  #
  # Least recently seen first, ties by id — the host tracker's own eviction
  # order (`{last_seen_ms, id}`), on the frame counter that is this core's
  # clock. What this frame matched has the highest `frame_id` there is, so a
  # cap wide enough for the scene never touches it.
  defp trim_live(%__MODULE__{max_live: :infinity} = state), do: {state, []}

  defp trim_live(state) do
    live = state.tracked ++ state.lost
    surplus = length(live) - state.max_live

    if surplus <= 0 do
      {state, []}
    else
      {evicted, _kept} = live |> Enum.sort_by(&{&1.frame_id, &1.id}) |> Enum.split(surplus)
      ids = MapSet.new(evicted, & &1.id)

      # Removed for good, as everything this core drops is, and without a
      # tombstone to say so: an evicted identity leaves no tracked, lost or
      # suspended entry behind, and those are the only pools a later frame can
      # draw an id from (see `tombstones/5`). There is nothing left that could
      # walk it back into the lost list.
      state = %{
        state
        | tracked: Enum.reject(state.tracked, &(&1.id in ids)),
          lost: Enum.reject(state.lost, &(&1.id in ids))
      }

      {state, for(track <- evicted, track.seen?, do: ended(track, :evicted, state.at_ms))}
    end
  end

  # What this frame published is what the next one reasons from: `seen?` is
  # what keeps an identity's `:started` and its `:ended` to exactly one each,
  # and an adoption is spent the moment it has been announced.
  defp remember(track) do
    %{
      track
      | seen?: track.seen? or track.activated?,
        adopted?: track.adopted? and not track.activated?
    }
  end

  # Nothing to expire without a clock — a host that ships no `at_ms` has
  # nothing to measure a window against, and could not have cut on one either
  # — and nothing to expire with an empty suspension list, which is every
  # frame of a run that never cuts.
  defp expire_lapsed(state, nil), do: {state, []}
  defp expire_lapsed(%__MODULE__{suspended: []} = state, _at_ms), do: {state, []}
  defp expire_lapsed(state, at_ms), do: expire_suspended(state, at_ms)

  @impl true
  @spec suspend(t(), pos_integer(), number()) ::
          {t(), [tuple()], Membrane.MOTTracker.Core.suspension()}
  def suspend(%__MODULE__{} = state, max_suspended, cut_ms) do
    entering =
      for track <- state.tracked,
          track.activated?,
          do: %{
            id: track.id,
            bbox: tlwh(track),
            score: track.score,
            label: track.label,
            seen?: track.seen?,
            cut_ms: cut_ms
          }

    {kept, evicted} = trim_suspended(state.suspended ++ entering, max_suspended)

    dropped = Enum.reject(state.tracked, & &1.activated?) ++ state.lost

    events =
      for(track <- dropped, track.seen?, do: ended(track, :stream_reset, cut_ms)) ++
        Enum.map(evicted, &ended(&1, :stream_reset, cut_ms))

    state = %{state | tracked: [], lost: [], suspended: kept}

    {state, events, %{suspended: length(kept), ended: length(events), at: state.at_ms}}
  end

  # The cap is over the whole suspension list and not over the arrivals alone:
  # a stream flapping between epochs would otherwise keep a generation of
  # ghosts per attempt, and the cap exists precisely because it flaps.
  #
  # Newest first, ties by id, keeping the head — the host tracker's own
  # eviction order: the ghosts of the reset before last are the ones a
  # reconnect loop should lose, and they are also the ones closest to their
  # window running out anyway. Sorting unconditionally is what makes the
  # checkpoint order a function of the set rather than of the order the cuts
  # happened to arrive in.
  defp trim_suspended(suspended, max_suspended) do
    suspended
    |> Enum.sort_by(&{-&1.cut_ms, &1.id})
    |> Enum.split(max_suspended)
  end

  @impl true
  @spec expire_suspended(t(), number()) :: {t(), [tuple()]}
  def expire_suspended(%__MODULE__{} = state, at_ms) do
    {lapsed, held} =
      Enum.split_with(state.suspended, &(at_ms - &1.cut_ms > @adoption_window_ms))

    {%{state | suspended: held}, Enum.map(lapsed, &ended(&1, :stream_reset, at_ms))}
  end

  @impl true
  @spec end_all(t(), atom()) :: {t(), [tuple()]}
  def end_all(%__MODULE__{} = state, reason) do
    live =
      for track <- state.tracked ++ state.lost, track.seen?, do: ended(track, reason, state.at_ms)

    suspended = Enum.map(state.suspended, &ended(&1, :stream_reset, state.at_ms))

    {%{state | tracked: [], lost: [], suspended: []}, live ++ suspended}
  end

  @impl true
  @spec checkpoint_tracks(t()) :: [map()]
  def checkpoint_tracks(%__MODULE__{} = state) do
    live = for track <- state.tracked ++ state.lost, track.seen?, do: summary(track, state.at_ms)

    live ++ Enum.map(state.suspended, &summary(&1, state.at_ms))
  end

  @impl true
  @spec adoption_window_ms() :: pos_integer()
  def adoption_window_ms, do: @adoption_window_ms

  # -- the frame, in the reference's order ------------------------------------

  defp split_by_score(objects, state) do
    high = for object <- objects, object.score > state.track_thresh, do: detection(object)

    low =
      for object <- objects,
          object.score > state.low_thresh and object.score < state.track_thresh,
          do: detection(object)

    {high, low}
  end

  defp detection(object) do
    %{
      id: nil,
      seed: object.bbox,
      filter: nil,
      state: :new,
      activated?: false,
      seen?: false,
      adopted?: false,
      score: object.score,
      label: Map.get(object, :label),
      tracklet_len: 0,
      frame_id: 0,
      start_frame: 0
    }
  end

  # A pool member that is not tracked may go on drifting but not on growing.
  defp predict(track) do
    filter =
      if track.state == :tracked,
        do: track.filter,
        else: Kalman.freeze_size_velocity(track.filter)

    %{track | filter: Kalman.predict(filter)}
  end

  # The depth cascade: split both sides into sublevels by pseudo-depth and
  # associate level by level, each level inheriting the last one's leftovers.
  # Where one side has more levels than the other, the surplus levels' members
  # are set aside unmatched rather than folded in — the reference's own choice,
  # and the reason a level count is a tuning knob rather than a partition.
  defp cascade(detections, tracks, {activated, refind}, stage) do
    det_masks = if detections == [], do: [], else: depth_masks(detections, stage.levels)
    track_masks = if tracks == [], do: [], else: depth_masks(tracks, stage.levels)

    if track_masks == [] do
      {activated, refind, [], detections}
    else
      surplus_dets = surplus(detections, det_masks, length(track_masks))
      surplus_tracks = surplus(tracks, track_masks, length(det_masks))

      {activated, refind, u_tracks, u_dets} =
        [det_masks, track_masks]
        |> Enum.zip()
        |> Enum.reduce({activated, refind, [], []}, fn masks, carried ->
          level(detections, tracks, masks, carried, stage)
        end)

      {activated, refind, u_tracks ++ surplus_tracks, u_dets ++ surplus_dets}
    end
  end

  defp level(detections, tracks, {det_mask, track_mask}, carried, stage) do
    {activated, refind, u_tracks, u_dets} = carried
    level_dets = select(detections, det_mask) ++ u_dets
    level_tracks = select(tracks, track_mask) ++ u_tracks

    {matches, u_track, u_det} = associate(level_tracks, level_dets, stage.thresh, stage.fuse?)

    {activated, refind} =
      Enum.reduce(matches, {activated, refind}, fn {t, d}, matched ->
        apply_match(Enum.at(level_tracks, t), Enum.at(level_dets, d), matched, stage.frame_id)
      end)

    {activated, refind, Enum.map(u_track, &Enum.at(level_tracks, &1)),
     Enum.map(u_det, &Enum.at(level_dets, &1))}
  end

  # A track the last frame still had goes on; one that had been given up on is
  # re-found, and the reference keeps the two apart because only the second is
  # news to anything downstream.
  defp apply_match(%{state: :tracked} = track, detection, {activated, refind}, frame_id) do
    {activated ++ [update(track, detection, frame_id)], refind}
  end

  defp apply_match(track, detection, {activated, refind}, frame_id) do
    {activated, refind ++ [reactivate(track, detection, frame_id)]}
  end

  defp surplus(items, masks, paired) when length(masks) > paired do
    masks |> Enum.drop(paired) |> Enum.flat_map(&select(items, &1))
  end

  defp surplus(_items, _masks, _paired), do: []

  defp select(items, mask) do
    for {item, true} <- Enum.zip(items, mask), do: item
  end

  # A track minted last frame is confirmed by a second sighting or discarded.
  # It never reaches the two stages: an identity nothing has corroborated may
  # not compete with one that has.
  defp confirm(unconfirmed, detections, frame_id, state) do
    {matches, u_unconfirmed, u_detections} =
      associate(unconfirmed, detections, state.confirm_thresh, not state.mot20)

    confirmations =
      for {t, d} <- matches,
          do: update(Enum.at(unconfirmed, t), Enum.at(detections, d), frame_id)

    removed = for t <- u_unconfirmed, do: %{Enum.at(unconfirmed, t) | state: :removed}

    {confirmations, removed, Enum.map(u_detections, &Enum.at(detections, &1))}
  end

  # What nothing matched mints a track, if it was confident enough to be worth
  # one. Adoption is spliced in here rather than into the association: a
  # suspended identity is not a track that can be matched, it is a name a new
  # track may take back — with a fresh filter, never the one the cut dropped.
  defp mint(detections, frame_id, at_ms, state) do
    Enum.reduce(detections, {[], state.next_id, state.suspended}, fn detection,
                                                                     {minted, next_id, suspended} ->
      cond do
        detection.score < state.det_thresh ->
          {minted, next_id, suspended}

        candidate = adoptable(suspended, detection, at_ms, state) ->
          {minted ++ [adopt(detection, candidate, frame_id)], next_id,
           List.delete(suspended, candidate)}

        true ->
          {minted ++ [activate(detection, next_id + 1, frame_id)], next_id + 1, suspended}
      end
    end)
  end

  # An adopted identity resumes the lifecycle it was suspended with. Minting it
  # afresh would lose that: an identity downstream has already been told about
  # would either vanish without the one final it is owed (a miss before the
  # confirmation, which discards an unseen track silently) or be announced a
  # second time as `:started`. What it does *not* skip is the confirmation —
  # nothing observed the cut, so one box across it is one box, exactly as for
  # any other minted track — so `:adopted` goes out when the identity is next
  # published, which is what `adopted?` holds until.
  defp adopt(detection, candidate, frame_id) do
    %{activate(detection, candidate.id, frame_id) | seen?: candidate.seen?, adopted?: true}
  end

  defp adoptable(suspended, detection, at_ms, state) do
    suspended
    |> Enum.filter(fn candidate ->
      (at_ms == nil or at_ms - candidate.cut_ms <= @adoption_window_ms) and
        iou(tlbr(candidate.bbox), tlbr(detection.seed)) >= state.adoption_iou
    end)
    |> Enum.max_by(&iou(tlbr(&1.bbox), tlbr(detection.seed)), fn -> nil end)
  end

  defp update(track, detection, frame_id) do
    %{
      track
      | filter: Kalman.update(track.filter, xywh(detection.seed)),
        frame_id: frame_id,
        tracklet_len: track.tracklet_len + 1,
        state: :tracked,
        activated?: true,
        score: detection.score,
        label: detection.label
    }
  end

  defp reactivate(track, detection, frame_id) do
    %{
      track
      | filter: Kalman.update(track.filter, xywh(detection.seed)),
        frame_id: frame_id,
        tracklet_len: 0,
        state: :tracked,
        activated?: true,
        score: detection.score,
        label: detection.label
    }
  end

  # The very first frame's tracks are activated on sight: there is no previous
  # frame that could have corroborated them, so the reference waives the
  # confirmation rather than starting every sequence one frame late.
  defp activate(detection, id, frame_id) do
    %{
      detection
      | id: id,
        filter: Kalman.initiate(xywh(detection.seed)),
        tracklet_len: 0,
        state: :tracked,
        activated?: frame_id == 1,
        frame_id: frame_id,
        start_frame: frame_id
    }
  end

  # -- pseudo-depth -----------------------------------------------------------

  # The sublevel membership of each item, as a list of one boolean list per
  # level. Bounds are half-open except the last, which closes — so every item
  # lands in exactly one level.
  defp depth_masks(items, levels) do
    depths = Enum.map(items, &depth/1)
    {near, far} = Enum.min_max(depths)

    range =
      if near == far do
        [near]
      else
        stepped = arange(near, far, (far - near + 1) / levels)

        if List.last(stepped) < far do
          bounded = stepped ++ [far]

          bounded
          |> List.replace_at(0, :math.floor(near))
          |> List.replace_at(length(bounded) - 1, :math.ceil(far))
        else
          stepped
        end
      end

    sub_masks(range, depths)
  end

  defp sub_masks(range, depths) do
    first = hd(range)
    last = List.last(range)

    {masks, _lower} =
      Enum.reduce(range, {[], first}, fn bound, {masks, lower} ->
        cond do
          bound > first and bound < last ->
            {masks ++ [Enum.map(depths, &(&1 >= lower and &1 < bound))], bound}

          bound == last ->
            {masks ++ [Enum.map(depths, &(&1 >= lower and &1 <= bound))], bound}

          true ->
            {masks, bound}
        end
      end)

    masks
  end

  defp depth(item) do
    [_x, y, _w, h] = tlwh(item)
    @depth_horizon - (y + h)
  end

  # `numpy.arange` for floats, reproduced rather than approximated: the second
  # element is one step from the start, and every element after it is the start
  # plus a multiple of the *realized* first step — which is not the requested
  # step once rounding has had its say, and produces different values.
  defp arange(start, stop, step) do
    length = max(0, ceil((stop - start) / step))
    second = start + step
    delta = second - start

    case length do
      0 -> []
      1 -> [start]
      _more -> [start, second] ++ for(i <- 2..(length - 1)//1, do: start + i * delta)
    end
  end

  # -- association arithmetic -------------------------------------------------

  # Empty on either side is not an assignment problem: the reference's solver
  # short-circuits a zero-sized matrix and hands everything back unmatched.
  defp associate([], detections, _thresh, _fuse?), do: {[], [], indices(detections)}
  defp associate(tracks, [], _thresh, _fuse?), do: {[], indices(tracks), []}

  defp associate(tracks, detections, thresh, fuse?) do
    tracks
    |> iou_distance(detections)
    |> fuse_score(detections, fuse?)
    |> Assignment.solve(thresh)
  end

  defp indices(items), do: Enum.to_list(0..(length(items) - 1)//1)

  defp iou_distance(tracks, detections) do
    boxes = Enum.map(detections, &tlbr(tlwh(&1)))

    for track <- tracks, box = tlbr(tlwh(track)), do: for(other <- boxes, do: 1 - iou(box, other))
  end

  # The score-weighted cost: an overlap with a confident detection is treated as
  # a better match than the same overlap with an unsure one. Written as the
  # reference writes it — the similarity recovered from the cost rather than
  # kept, because `1 - (1 - x)` is not `x` and the difference decides matches.
  defp fuse_score(cost, _detections, false), do: cost

  defp fuse_score(cost, detections, true) do
    scores = Enum.map(detections, & &1.score)

    for row <- cost,
        do: Enum.zip_with(row, scores, fn value, score -> 1 - (1 - value) * score end)
  end

  # `cython_bbox`'s convention: a box's extent counts both its edges, so a
  # one-pixel box is one pixel wide rather than zero. Pixels, therefore — see
  # the moduledoc.
  defp iou([ax1, ay1, ax2, ay2], [bx1, by1, bx2, by2]) do
    width = max(min(ax2, bx2) - max(ax1, bx1) + 1, 0)
    height = max(min(ay2, by2) - max(ay1, by1) + 1, 0)
    intersection = width * height

    union =
      (ax2 - ax1 + 1) * (ay2 - ay1 + 1) + (bx2 - bx1 + 1) * (by2 - by1 + 1) - intersection

    # A union of exactly 0.0 takes a degenerate prediction (an extent of
    # exactly -1, so both +1 areas cancel) — the reference's float division
    # yields nan silently there, and BEAM float division raises. No overlap is
    # the only sane reading, and on any input the parity gate runs, this
    # clause is unreachable.
    if union == 0.0, do: 0.0, else: intersection / union
  end

  defp tlbr([x, y, w, h]), do: [x, y, x + w, y + h]
  defp xywh([x, y, w, h]), do: [x + w / 2, y + h / 2, w, h]

  defp tlwh(%{filter: nil, seed: seed}), do: seed
  defp tlwh(%{filter: filter}), do: Kalman.tlwh(filter)
  defp tlwh(%{bbox: bbox}), do: bbox

  # -- bookkeeping ------------------------------------------------------------

  # The reference mutates its tracks in place, so a list that holds one holds
  # whatever this frame did to it. Here the frame's changed tracks are carried
  # separately and folded back in by identity.
  defp resolve(track, changed) do
    Enum.find(changed, track, &(&1.id == track.id))
  end

  # Union by identity, keeping the first list's order — the reference's
  # `joint_stracks`.
  defp joint(first, second) do
    known = MapSet.new(first, & &1.id)

    first ++ Enum.reject(second, &(&1.id in known))
  end

  # `:adopted` follows the identity's own `:updated`, as the host tracker emits
  # the pair: a consumer folding the events in order has the resumed summary
  # before it is told the resumption happened. It is only ever emitted for an
  # identity that has been published before, so no consumer meets one it has
  # not already been told about.
  defp lifecycle(output, gone, at_ms) do
    started = for track <- output, not track.seen?, do: {:started, summary(track, at_ms)}
    updated = for track <- output, track.seen?, do: {:updated, summary(track, at_ms)}
    adopted = for track <- output, track.adopted?, do: {:adopted, summary(track, at_ms)}
    ended = for track <- gone, track.seen?, do: ended(track, :lost, at_ms)

    started ++ updated ++ adopted ++ ended
  end

  defp ended(track, reason, at_ms) do
    {:ended, track |> summary(at_ms) |> Map.put(:reason, reason)}
  end

  defp summary(track, at_ms) do
    %{
      object_id: track.id,
      bbox: tlwh(track),
      score: track.score,
      label: track.label,
      at_ms: at_ms
    }
  end
end
