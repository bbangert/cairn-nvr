defmodule Cairn.Native.Observations do
  @moduledoc """
  `Cairn.Native.push_au/4`'s frames as `Cairn.Observation`s.

  `Cairn.PluginProtocol`'s byte-level revalidation is deliberately absent: there
  is no serialization and no other process here, and `det_from`
  (`plugins/cairn-detect/src/infer/heads.rs`) already clamped the score, shaped
  the label and refused a zero-extent box. What is left is what guards against a
  bug of ours — the bbox clamp and the object cap.
  """

  alias Cairn.Observation
  alias Cairn.ObservationClock

  # `decode::pts_90k` dates every frame the crate emits, so the clock is fixed
  # rather than announced.
  @time_base {1, 90_000}
  # The contract's per-line cap (`emit::MAX_OBJECTS`), which the producer cannot
  # reach — `infer::MAX_DETS` cuts a pass at 32 — so it bounds a bug of ours. It
  # keeps the head, which is ordered by evidence then score.
  @max_objects 64

  @doc """
  One push's frames, stamped onto `clock`.

  `now_ms` is the host's monotonic clock — `Cairn.CameraTracker` compares the
  resulting `at_ms` against its own reading of it — and is read once per push,
  not per frame. Frames sharing it still take distinct `at_ms`:
  `Cairn.ObservationClock`'s floor makes the stamp strictly increasing.
  """
  @spec from_frames(ObservationClock.t(), [map()], String.t(), String.t() | nil, number()) ::
          {[Observation.t()], ObservationClock.t()}
  def from_frames(%ObservationClock{} = clock, frames, camera_id, epoch, now_ms) do
    Enum.map_reduce(frames, clock, fn frame, clock ->
      ObservationClock.stamp(clock, from_frame(frame, camera_id, epoch), now_ms)
    end)
  end

  @doc """
  One frame, without `at_ms` — for a caller comparing detections rather than
  tracking with them (`Cairn.Native.Parity`).
  """
  @spec from_frame(map(), String.t(), String.t() | nil) :: Observation.t()
  def from_frame(%{pts: pts, observed_at_ms: observed_at_ms, objects: objects}, camera_id, epoch) do
    {observed_at, quality} = observed_at(observed_at_ms)
    {objects, invalid} = bounded_objects(objects)

    # `sequence` and `plugin_instance` describe a wire and the process that wrote
    # it, and there is no pipe here; the NIF mints no identity to end, so
    # `ended_tracks` stays empty.
    %Observation{
      camera_id: camera_id,
      epoch: epoch,
      pts: pts,
      time_base: @time_base,
      media_ms: Observation.media_ms(pts, @time_base),
      observed_at: observed_at,
      time_quality: quality,
      objects: objects,
      invalid_objects: invalid,
      protocol: :v1
    }
  end

  # `stream.rs`'s `unix_ms` answers `i64::MAX` for a clock too far ahead to express
  # — the one value arriving here that is not a time.
  defp observed_at(unix_ms) do
    case DateTime.from_unix(unix_ms, :millisecond) do
      {:ok, at} -> {microsecond_precision(at), :source}
      {:error, _reason} -> {DateTime.utc_now(), :arrival}
    end
  end

  # `Ecto.Type.check_usec!` raises on a `:utc_datetime_usec` at any precision but
  # 6, and `Cairn.Tracks` writes with `insert_all`, which dumps without casting.
  # Only the declared precision moves.
  defp microsecond_precision(%DateTime{microsecond: {value, _digits}} = at),
    do: %{at | microsecond: {value, 6}}

  defp bounded_objects(objects) do
    {kept, over_cap} = Enum.split(objects, @max_objects)

    {bounded, invalid} =
      Enum.reduce(kept, {[], length(over_cap)}, fn object, {bounded, invalid} ->
        case bounded(object) do
          {:ok, object} -> {[object | bounded], invalid}
          :error -> {bounded, invalid + 1}
        end
      end)

    {Enum.reverse(bounded), invalid}
  end

  # Clamped and not refused, as the producer's `wire_bbox` does. What cannot be
  # clamped is a box with no extent left: `Cairn.Tracker.iou/2` scores it 0 against
  # everything, so it would mint a fresh identity every frame it appeared in.
  defp bounded(%{bbox: [x, y, w, h]} = object)
       when is_number(x) and is_number(y) and is_number(w) and is_number(h) do
    case [unit(x), unit(y), unit(w), unit(h)] do
      [_x, _y, w, h] = bbox when w > 0 and h > 0 -> {:ok, %{object | bbox: bbox}}
      _degenerate -> :error
    end
  end

  defp bounded(_object), do: :error

  # Floats out: an integer bound would leave a `0` where every other bbox
  # component is a `0.0`, and that difference reaches JSON.
  defp unit(n) when n < 0, do: 0.0
  defp unit(n) when n > 1, do: 1.0
  defp unit(n), do: n
end
