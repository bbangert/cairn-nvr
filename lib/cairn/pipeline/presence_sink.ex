defmodule Cairn.Pipeline.PresenceSink do
  @moduledoc """
  The tier-1 detect branch's terminus: `Cairn.Pipeline.Inference`'s
  detections go straight to the camera's `Cairn.PresenceAggregator`, and
  nothing tracking-shaped ever exists — no `Cairn.Pipeline.ObservationStamper`,
  no `Membrane.MOTTracker`, no `Cairn.Pipeline.TrackSink`, no
  `Cairn.CameraTracker` (D-S2; the fork is `Cairn.Pipeline.Camera`'s
  `detect_spec/3`).

  The two per-buffer admissions `ObservationStamper` reads for the tracked
  path are read here for the same reasons, from the same table:

    * `detection_enabled` off drops the batch and tells the aggregator once
      per transition — an operator switched watching off, which is a louder
      fact than a closed gate, so presence clears rather than holds.
    * `min_score` floors what counts as evidence, override semantics
      identical to the stamper's — a runtime override replaces the camera's
      thresholds as the default for every label.

  Only `observation_kind == "detected"` objects are evidence — a `"tracked"`
  object is a predictor's guess (`Cairn.Observation`), and tier 1 runs no
  predictor to vouch for one. An empty surviving set is still forwarded:
  frames flowed and nothing qualified, which is exactly the evidence of
  absence the aggregator's gate-aware clearing waits for.

  Containment runs once, here, ahead of the fan-out (`Cairn.Zones.hits/2` on
  each box's bottom centre): on a camera with zones an object outside every
  one of them is dropped, so neither presence state nor a recording can be
  founded on a box the operator drew their zones to exclude. The aggregator
  gets the fold over what survived, keyed `{zone, label}` — a zoneless
  camera drops nothing and reports the whole-frame key `nil`.
  `Cairn.PresenceRecorder` gets those same surviving frames unfolded, boxes
  and all, because a recording wants what presence state has no use for —
  the trigger box its snapshot is drawn on and the dense sidecar its
  playback overlay reads. `Cairn.LiveDetections` gets the boxes on their own
  node-local topic for the dashboard's live overlay, and alone among the
  three is shown everything: the detections the floors reject, and the ones
  the zones reject, for the same reason — an operator tuning either needs to
  see what it is rejecting.
  """

  use Membrane.Sink

  alias Cairn.{CameraControl, LiveDetections, PresenceAggregator, PresenceRecorder, Zones}
  alias Cairn.Config.Camera
  alias Cairn.Pipeline.Inference.Detections
  alias Membrane.Buffer

  def_input_pad(:input, accepted_format: %Detections{}, flow_control: :auto)

  def_options(camera: [spec: Camera.t()])

  @impl true
  def handle_init(_ctx, opts) do
    {[],
     %{
       camera: opts.camera,
       # Once per transition, like the stamper's `detecting?`.
       detecting?: true,
       forwarded: 0,
       dropped: 0,
       # Monotonic, for the owner's watchdog — the tier-1 spelling of
       # `Cairn.Pipeline.TrackSink`'s liveness field: without it a tier-1
       # camera's `detect_at_ms` stays nil and `detect_stale?/1` can never
       # notice a wedged inference branch.
       last_buffer_at_ms: nil
     }}
  end

  # Matched, not dot-accessed, for the stamper's reason: a `Detections`
  # producer whose buffer lacks the key falls to the counted drop rather
  # than crashing the element. No epoch requirement — presence carries no
  # identity for a session boundary to confuse.
  @impl true
  def handle_buffer(:input, %Buffer{metadata: %{observations: observations}}, _ctx, state)
      when is_list(observations) do
    forward(state, observations, CameraControl.get(state.camera.id))
  end

  def handle_buffer(:input, _buffer, _ctx, state) do
    {[], %{state | dropped: state.dropped + 1}}
  end

  defp forward(state, _observations, %{detection_enabled: false}) do
    if state.detecting? do
      PresenceAggregator.detection_disabled(state.camera.id)

      # The overlay has no staleness timer by design, so silence reads as
      # "the last boxes still hold" — over a video that is still playing.
      # Switching detection off has to say so once, in the only vocabulary
      # the topic has: an empty frame.
      LiveDetections.broadcast(state.camera.id, [])
    end

    {[], %{state | detecting?: false, dropped: state.dropped + 1}}
  end

  defp forward(state, observations, control) do
    floors = effective_min_score(state.camera, control)
    now_ms = System.monotonic_time(:millisecond)

    # Model-inferred frames only, and the filter is in the pattern: on a
    # native motion-gate skip the engine replays the last pass's objects as
    # `"tracked"` predictions under `inferred: false` (cairn-ort's
    # `Decision::Skip`) — the model never looked, so such a frame is
    # evidence of nothing, exactly like the silence a pipeline-level gate
    # produces. It still proves the branch alive (the liveness stamp below
    # covers every buffer).
    inferred = Enum.filter(observations, &match?(%{inferred: true}, &1))
    zoned = Enum.map(inferred, &zone_objects(&1, state.camera.zones))

    # One aggregator call per frame, not per buffer — but unlike the
    # stamper's clock, which derives a distinct `at_ms` per frame, every
    # frame here shares the buffer's one reading. That is enough because the
    # aggregator counts sightings per CALL: presence needs to know the class
    # was seen again, not when to the millisecond.
    #
    # A zoned frame emptied by the filter still calls `observed`: frames
    # flowed and nothing qualified inside the zones, which is the evidence of
    # absence the aggregator's clearing waits for.
    for frame <- zoned do
      PresenceAggregator.observed(state.camera.id, now_ms, seen(frame, floors))
    end

    # The live grid's overlay, off the UNzoned frames and unconditional: the
    # payload is a handful of floats and the topic is node-local, so a camera
    # nobody is watching costs one `local_broadcast` into an empty subscriber
    # list per frame. One message per frame, like the aggregator loop above —
    # each replaces the subscriber's list, so a multi-frame buffer simply ends
    # with its last frame on screen.
    for frame <- inferred do
      LiveDetections.broadcast(
        state.camera.id,
        LiveDetections.from_objects(Map.get(frame, :objects, []))
      )
    end

    # The zoned frames again, whole: `seen/2`'s fold to
    # `%{{zone, label} => score}` is presence-state economy, not a data
    # limit, and the event lane needs the boxes it drops (D-E5). Zoned and
    # not `inferred`, unlike the overlay above — a box outside every zone
    # must never become an event's trigger or land in the sidecar, since the
    # event it would illustrate is one the aggregator refused to open. The
    # floors ride along because they are the sink's, override included, and
    # the recorder has no other way to know what this batch was judged
    # against. With no event open it holds only the latest batch and drops
    # the rest, so an idle camera pays one cast per buffer and no growing
    # state.
    if zoned != [] do
      PresenceRecorder.frames(state.camera.id, floors, zoned)
    end

    # All-skip buffers still prove the stream alive to the aggregator's
    # silence backstop — a gated scene is not a dead camera.
    if inferred == [] and observations != [] do
      PresenceAggregator.heartbeat(state.camera.id, now_ms)
    end

    {[],
     %{
       state
       | detecting?: true,
         forwarded: state.forwarded + length(observations),
         last_buffer_at_ms: now_ms
     }}
  end

  # Tags every object with the zones its box lands in and, on a camera that
  # has zones, keeps only the ones that landed somewhere. The `:zones` tag is
  # this element's own and deliberately outside `Cairn.Observation`'s object
  # type — nothing before the sink knows a zone exists.
  #
  # Any box is placed, whatever its `observation_kind`: a predicted box stays
  # in the recorder's frames on a zoned camera exactly as it does on a
  # zoneless one, and `seen/2` is what keeps evidence to `"detected"`. A
  # boxless object has nothing to place it by, so the asymmetry is there: a
  # zoned camera drops it, a zoneless one passes it through as before.
  defp zone_objects(frame, zones) do
    tagged =
      for object <- Map.get(frame, :objects, []), do: Map.put(object, :zones, hits(zones, object))

    kept = if zones == [], do: tagged, else: Enum.filter(tagged, &(&1.zones != []))

    Map.put(frame, :objects, kept)
  end

  defp hits(zones, %{bbox: [_, _, _, _] = bbox}), do: Zones.hits(zones, bbox)

  defp hits(_zones, _object), do: []

  defp seen(frame, floors) do
    frame
    |> Map.get(:objects, [])
    |> Enum.filter(&evidence?(&1, floors))
    |> Enum.flat_map(fn object -> Enum.map(keys(object), &{&1, object.score}) end)
    |> Enum.reduce(%{}, fn {key, score}, seen -> Map.update(seen, key, score, &max(&1, score)) end)
  end

  defp evidence?(object, floors),
    do: object.observation_kind == "detected" and object.score >= floor_for(floors, object.label)

  # One key per containing zone — the same label standing in two overlapping
  # zones owes two independent presence states. An empty list reaches here
  # only from a zoneless camera, `zone_objects/2` having dropped it
  # otherwise, and is the whole-frame key.
  defp keys(%{zones: []} = object), do: [{nil, object.label}]
  defp keys(object), do: for(zone <- object.zones, do: {zone, object.label})

  # `Cairn.Tracker.floor_for/2`'s rule, spelled again because that one is
  # private to the tracker a tier-1 camera never runs: the label's own floor,
  # else the default, else 0.5.
  defp floor_for(floors, label), do: Map.get(floors, label) || Map.get(floors, "default", 0.5)

  defp effective_min_score(camera, %{min_score: nil}), do: camera.min_score || %{}
  defp effective_min_score(_camera, %{min_score: override}), do: %{"default" => override}

  # The reload seam, `ObservationStamper`'s: min_score lives on the camera
  # struct, so a reload must land here. The policy rides along unread —
  # nothing else in it applies to a branch with no tracker.
  #
  # Zones do apply, and their removal is the one edit presence cannot infer.
  # While frames flow the ordinary absence path gets there — the sink stops
  # producing the gone key and every later batch is evidence against it —
  # but a still scene produces no batches at all and the stale key would
  # stand to the 600 s backstop. So the edit says so outright, and the cast
  # lands behind this element's last `observed` cast on the same aggregator
  # mailbox: a batch already in flight cannot re-mint what it just cleared.
  # If the aggregator restarts between the two, its `init/1` ledger clear is
  # the backstop — a duplicate cleared at worst, never a missing one.
  #
  # `Cairn.Zones.removed/2` names what clears, and both directions of a flip
  # fall out of it: gaining the first zone removes the whole-frame key `nil`,
  # losing the last removes every id, and a reshaped outline removes its own
  # id — what clears is exactly what the new key space can no longer re-mint.
  # `Cairn.PipelineOwner` runs the same comparison for the case this element
  # cannot cover, a refresh with no pipeline to notify.
  @impl true
  def handle_parent_notification({:policy, camera, _policy}, _ctx, state) do
    removed = Zones.removed(state.camera.zones, camera.zones)

    if removed != [], do: PresenceAggregator.zones_removed(camera.id, removed)

    {[], %{state | camera: camera}}
  end

  # The owner's liveness read, `TrackSink`'s shape — it matches on
  # `last_buffer_at_ms` alone.
  def handle_parent_notification(:stats, _ctx, state) do
    stats = %{
      forwarded: state.forwarded,
      dropped: state.dropped,
      last_buffer_at_ms: state.last_buffer_at_ms
    }

    {[notify_parent: {:stats, stats}], state}
  end
end
