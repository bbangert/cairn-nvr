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
  """

  use Membrane.Sink

  alias Cairn.{CameraControl, PresenceAggregator}
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
       dropped: 0
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
    if state.detecting?, do: PresenceAggregator.detection_disabled(state.camera.id)
    {[], %{state | detecting?: false, dropped: state.dropped + 1}}
  end

  defp forward(state, observations, control) do
    floors = effective_min_score(state.camera, control)
    now_ms = System.monotonic_time(:millisecond)

    # One aggregator call per frame, not per buffer: a push's frames are
    # separate instants, same as the stamper's one-batch-per-buffer rule.
    for frame <- observations do
      PresenceAggregator.observed(state.camera.id, now_ms, seen(frame, floors))
    end

    {[], %{state | detecting?: true, forwarded: state.forwarded + length(observations)}}
  end

  defp seen(frame, floors) do
    frame
    |> Map.get(:objects, [])
    |> Enum.reduce(%{}, fn object, seen ->
      if object.observation_kind == "detected" and object.score >= floor_for(floors, object.label) do
        Map.update(seen, object.label, object.score, &max(&1, object.score))
      else
        seen
      end
    end)
  end

  # `Cairn.Tracker.floor_for/2`'s rule, spelled again because that one is
  # private to the tracker a tier-1 camera never runs: the label's own floor,
  # else the default, else 0.5.
  defp floor_for(floors, label), do: Map.get(floors, label) || Map.get(floors, "default", 0.5)

  defp effective_min_score(camera, %{min_score: nil}), do: camera.min_score || %{}
  defp effective_min_score(_camera, %{min_score: override}), do: %{"default" => override}

  # The reload seam, `ObservationStamper`'s: min_score lives on the camera
  # struct, so a reload must land here. The policy rides along unread —
  # nothing else in it applies to a branch with no tracker.
  @impl true
  def handle_parent_notification({:policy, camera, _policy}, _ctx, state) do
    {[], %{state | camera: camera}}
  end
end
