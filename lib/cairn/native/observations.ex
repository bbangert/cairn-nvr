defmodule Cairn.Native.Observations do
  @moduledoc """
  `Cairn.Native.push_au/4`'s frames as `Cairn.Observation`s.

  Byte-level revalidation is deliberately absent. `Cairn.PluginProtocol`
  re-establishes on arrival everything an untrusted OS process could have broken;
  on this path there is neither a serialization nor another process, and
  `det_from` (`plugins/cairn-detect/src/infer/heads.rs`) has already clamped the
  score, shaped the label and refused a zero-extent box. What survives is only
  what is cheap *and* guards a consumer against a bug of ours: the bbox clamp and
  the per-line object cap. The rest was the price of a boundary that no longer
  exists.
  """

  alias Cairn.Observation
  alias Cairn.ObservationClock

  # `decode::pts_90k` dates every frame the crate emits, so the clock is fixed
  # rather than announced.
  @time_base {1, 90_000}
  # The contract's per-line cap (`Cairn.PluginProtocol`'s 64, `emit::MAX_OBJECTS`),
  # which the producer cannot reach — `infer::MAX_DETS` cuts a pass at 32 — so it
  # bounds a bug. It sheds the way `emit::objects_line` does: keeping the head of
  # a list ordered by evidence then score, which drops the weakest first.
  @max_objects 64

  @doc """
  One push's frames, stamped onto `clock`.

  `now_ms` is read once per push and not per frame, for the reason
  `Stream::push_au` takes one `Instant` for the whole call: an access unit is one
  picture. Frames sharing it still take distinct `at_ms` —
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
    # `ended_tracks` stays empty. `protocol: :v1` is the distinction the field
    # carries downstream: the observation arrived with its own epoch and time.
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

  # `unix_ms` answers `i64::MAX` for a clock too far ahead to express as i64
  # milliseconds since 1970 (`plugins/cairn-native/src/stream.rs`) — the one value
  # arriving here that is not a time.
  defp observed_at(unix_ms) do
    case DateTime.from_unix(unix_ms, :millisecond) do
      {:ok, at} -> {microsecond_precision(at), :source}
      {:error, _reason} -> {DateTime.utc_now(), :arrival}
    end
  end

  # Ecto refuses to dump a `:utc_datetime_usec` at any precision but 6
  # (`Ecto.Type.check_usec!` raises), and `Cairn.Tracks` writes track index rows
  # with `insert_all`, which dumps without casting. Only the declared precision
  # moves; the count of microseconds is unchanged.
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

  # Clamped and not refused, because clamping is what the producer already does
  # (`wire_bbox`). What cannot be clamped into a box is one with no extent left:
  # `Cairn.Tracker.iou/2` scores it 0 against everything, so it would mint a fresh
  # identity every frame it appeared in. The guard is what makes the clamp total,
  # not a type check for its own sake.
  defp bounded(%{bbox: [x, y, w, h]} = object)
       when is_number(x) and is_number(y) and is_number(w) and is_number(h) do
    case [unit(x), unit(y), unit(w), unit(h)] do
      [_x, _y, w, h] = bbox when w > 0 and h > 0 -> {:ok, %{object | bbox: bbox}}
      _degenerate -> :error
    end
  end

  defp bounded(_object), do: :error

  # Floats in, floats out: an integer bound would leave a `0` where every other
  # bbox component is a `0.0`, and that difference reaches JSON.
  defp unit(n) when n < 0, do: 0.0
  defp unit(n) when n > 1, do: 1.0
  defp unit(n), do: n
end
