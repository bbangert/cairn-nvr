defmodule Cairn.TrackerDriver do
  @moduledoc """
  The detect branch's tracker half, driven inside the test process.

  A `Cairn.CameraTracker` no longer tracks anything: it consumes what
  `Cairn.Pipeline.TrackSink` casts, which is what `Membrane.MOTTracker` made of
  one batch of observations. A test that wants to say "this camera saw a person
  here" therefore has to produce that, and producing it by hand would be a
  second implementation of the pad contract in every test file.

  So this runs the **real** element and the **real** sink — `handle_buffer/4`
  and `handle_tick/3` called directly, no pipeline around them — over the real
  core, and dispatches the result through the real seam. What a test skips by
  using it is only the part above the tracker: `Cairn.Pipeline.Inference`, and
  the clock and control read in `Cairn.Pipeline.ObservationStamper` (an
  observation arrives here already stamped, which is what lets a test place a
  batch on the tracking clock to the millisecond).

  State lives in the process dictionary, keyed by camera id, so the helpers in
  a test file stay one-liners and nothing has to be threaded through two
  thousand lines of assertions. One element per camera per test process; it
  dies with the test.
  """

  alias Cairn.{CameraControl, Observation, Tracker}
  alias Cairn.Config.Camera
  alias Cairn.Pipeline.TrackSink
  alias Membrane.Buffer

  @doc """
  One observation through the element and the sink, to `server`.

  `server` is the sink's `tracker:` seam — the camera tracker under test, or a
  process standing in for it. `nil` routes to the camera's own tracker, as the
  seam does in production.
  """
  @spec detections(GenServer.server() | nil, Camera.t(), map(), Observation.t()) :: :ok
  def detections(server, %Camera{} = camera, policy, %Observation{} = observation) do
    observation = observation |> with_observed_at() |> with_at_ms()
    {tracker, sink} = state(server, camera, policy)

    buffer = %Buffer{
      payload: <<>>,
      pts: 0,
      metadata: %{
        objects: observation.objects,
        context: context(camera, policy, observation),
        at_ms: observation.at_ms,
        epoch: observation.epoch
      }
    }

    {actions, tracker} = Membrane.MOTTracker.handle_buffer(:input, buffer, %{}, tracker)
    put(camera.id, {tracker, drain(actions, sink)})
    :ok
  end

  @doc """
  One `Membrane.MOTTracker.Format.Observations` buffer straight through, for a
  test that ran the real `Cairn.Pipeline.ObservationStamper` and so has the
  contract already built rather than an observation to build it from.
  """
  @spec batch(GenServer.server() | nil, Camera.t(), map(), Buffer.t()) :: :ok
  def batch(server, %Camera{} = camera, policy, %Buffer{} = buffer) do
    {tracker, sink} = state(server, camera, policy)
    {actions, tracker} = Membrane.MOTTracker.handle_buffer(:input, buffer, %{}, tracker)
    put(camera.id, {tracker, drain(actions, sink)})
    :ok
  end

  @doc """
  The element's adoption sweep, at `at_ms` — its `handle_tick/3` with the cut
  it is waiting on moved so that `at_ms` is what the core is asked about.

  In production the timer fires `adoption_window_ms + 1s` after the cut and the
  element derives the instant from the cut it recorded; a test that wants a
  suspension to lapse would otherwise have to sit through a minute of it.
  """
  @spec sweep(GenServer.server() | nil, Camera.t(), map(), number()) :: :ok
  def sweep(server, %Camera{} = camera, policy, at_ms) do
    {tracker, sink} = state(server, camera, policy)
    tracker = %{tracker | cut_ms: at_ms - tracker.window_ms}

    {actions, tracker} = Membrane.MOTTracker.handle_tick(:adoption_window, %{}, tracker)
    put(camera.id, {tracker, drain(actions, sink)})
    :ok
  end

  @doc """
  Ends every track the element holds, under `reason` — the parent notification
  `Cairn.Pipeline.ObservationStamper` triggers when detection is turned off.
  """
  @spec end_all(GenServer.server() | nil, Camera.t(), map(), atom()) :: :ok
  def end_all(server, %Camera{} = camera, policy, reason) do
    {tracker, sink} = state(server, camera, policy)

    {actions, tracker} =
      Membrane.MOTTracker.handle_parent_notification({:end_all, reason}, %{}, tracker)

    put(camera.id, {tracker, drain(actions, sink)})
    :ok
  end

  @doc """
  The core's live tracks — what a test used to read out of the camera
  tracker's own state, now one process removed.
  """
  @spec live_tracks(String.t()) :: [Cairn.Track.t()]
  def live_tracks(camera_id), do: core(camera_id, &Tracker.live_tracks/1)

  @doc "The core's suspended tracks; `live_tracks/1`'s sibling."
  @spec suspended_tracks(String.t()) :: [Cairn.Track.t()]
  def suspended_tracks(camera_id), do: core(camera_id, &Tracker.suspended_tracks/1)

  defp core(camera_id, read) do
    case Process.get({__MODULE__, camera_id}) do
      nil -> []
      {tracker, _sink} -> read.(tracker.core)
    end
  end

  @doc """
  Forgets this camera's element — a fresh pipeline, which is what a rebuild is.
  """
  @spec reset(String.t()) :: :ok
  def reset(camera_id) do
    Process.delete({__MODULE__, camera_id})
    :ok
  end

  # Every buffer the element produced, through the sink that casts it. Timer
  # actions are dropped: this driver is the clock.
  defp drain(actions, sink) do
    Enum.reduce(actions, sink, fn
      {:buffer, {:output, buffer}}, sink ->
        {[], sink} = TrackSink.handle_buffer(:input, buffer, %{}, sink)
        sink

      _timer, sink ->
        sink
    end)
  end

  defp state(server, camera, policy) do
    case Process.get({__MODULE__, camera.id}) do
      nil ->
        {[], tracker} =
          Membrane.MOTTracker.handle_init(
            %{},
            struct(Membrane.MOTTracker,
              tracker: {Tracker, []},
              max_suspended: Map.get(policy, :max_live_tracks) || 128
            )
          )

        {[], sink} =
          TrackSink.handle_init(
            %{},
            struct(TrackSink, camera: camera, policy: policy, tracker: server)
          )

        {tracker, sink}

      # The camera and policy of the batch, not of the first one: both ride
      # every cast, and a test that refreshes either expects the next batch to
      # carry it.
      {tracker, sink} ->
        {tracker, %{sink | camera: camera, policy: policy, tracker: server}}
    end
  end

  defp put(camera_id, state), do: Process.put({__MODULE__, camera_id}, state)

  # The two stamps production cannot be missing — `Cairn.Native.Observations`
  # dates every frame and `Cairn.ObservationClock` clocks it — and a fixture
  # written before either mattered can be. `Cairn.CameraTracker` used to carry
  # this guard because it was a public entry point; the guard belonged to the
  # test seams that were its only callers, and this is that seam now. `at_ms`
  # from the host clock dates the batch's arrival and carries none of the
  # spacing between frames, which every caller here that cares sets itself.
  defp with_observed_at(%Observation{observed_at: at} = observation)
       when is_struct(at, DateTime),
       do: observation

  defp with_observed_at(observation), do: %{observation | observed_at: DateTime.utc_now()}

  defp with_at_ms(%Observation{at_ms: at_ms} = observation) when is_number(at_ms), do: observation

  defp with_at_ms(observation),
    do: %{observation | at_ms: System.monotonic_time(:millisecond)}

  # What `Cairn.Pipeline.ObservationStamper` resolves per buffer, minus the
  # clock: the policy's bounds defaulted, with the runtime `min_score` override
  # folded in — the number the core partitions on *and* the number the event
  # gate downstream reads back off the batch. Defaulted here for the reason the
  # stamper defaults them: a policy handed to this driver by a test is a bare
  # map, not `Cairn.Config.policy/2`'s.
  defp context(camera, policy, observation) do
    min_score =
      case CameraControl.get(camera.id) do
        %{min_score: nil} -> camera.min_score
        %{min_score: override} -> %{"default" => override}
      end

    policy =
      policy
      |> Map.put_new(:max_unseen_ms, Cairn.Config.default_max_unseen_ms())
      |> Map.put_new(:max_live_tracks, Cairn.Config.default_max_live_tracks())
      |> Map.put_new(:stationary_after_ms, Cairn.Config.default_stationary_after_ms())
      |> Map.put(:min_score, min_score)

    Tracker.context(observation, camera.id, policy)
  end
end
