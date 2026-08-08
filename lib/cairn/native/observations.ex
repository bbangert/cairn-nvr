defmodule Cairn.Native.Observations do
  @moduledoc """
  What `Cairn.Native.push_au/4` returned, as `Cairn.Observation`s.

  The NIF answers one map per frame the access unit completed — `pts` on the
  90 kHz clock, `observed_at_ms`, `inferred`, and objects already in the
  struct's own spelling (`plugins/cairn-native/src/observation.rs`, which builds
  them by hand so that `embedding` is *absent* rather than `nil` when there is
  none). What is left for this side is the envelope the wire used to carry, and
  the `at_ms` stamp.

  Both paths carry the same `cairn_detect::emit::Det`. The plugin serializes it
  to JSON, and `Cairn.PluginProtocol` re-establishes on arrival everything an
  untrusted OS process could have broken in between; here there is neither a
  serialization nor another process, and `det_from`
  (`plugins/cairn-detect/src/infer/heads.rs`) has already clamped the score,
  shaped the label and refused a zero-extent box before either path sees the
  detection. So what survives on this side is only what is cheap *and* guards a
  consumer against a bug of ours: the bbox components into 0..1, and the
  contract's per-line object cap. Type checks,
  field presence and the pts magnitude bound are gone — the last one is enforced
  in the crate (`plugins/cairn-native/src/stream.rs`), and the rest were the
  price of a boundary that no longer exists.

  What `Cairn.PluginPort` does *around* the equivalent of this — refusing a
  stale epoch, counting drops, forwarding to `Cairn.CameraTracker` — stays with
  the caller. Its ±30 s skew clamp has nothing left to compare: `observed_at`
  here is this host's own wall clock, not another machine's.
  """

  alias Cairn.Observation
  alias Cairn.ObservationClock

  # `decode::pts_90k` dates every frame the crate emits, so the clock is fixed
  # rather than announced — this is also the host's default for a line that
  # carries no `time_base`.
  @time_base {1, 90_000}
  # The contract's per-line cap (`Cairn.PluginProtocol`'s 64, `emit::MAX_OBJECTS`),
  # which the producer cannot reach: `infer::MAX_DETS` cuts a pass at 32, and a
  # gated frame re-reports a subset of one. So this bounds a bug, and it sheds
  # the way `emit::objects_line` does: keeping the head of a list ordered by
  # evidence then score, which drops the weakest first.
  @max_objects 64

  @doc """
  One push's frames, stamped onto `clock`.

  `now_ms` is the host's monotonic clock, read once per push and not per frame
  for the reason `Stream::push_au` takes one `Instant` for the whole call: an
  access unit is one picture. Two frames sharing it still take distinct `at_ms`
  — `Cairn.ObservationClock`'s floor is what makes the stamp strictly
  increasing.
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
  tracking with them (task 2.5's parity harness).
  """
  @spec from_frame(map(), String.t(), String.t() | nil) :: Observation.t()
  def from_frame(%{pts: pts, observed_at_ms: observed_at_ms, objects: objects}, camera_id, epoch) do
    {observed_at, quality} = observed_at(observed_at_ms)
    {objects, invalid} = bounded_objects(objects)

    # `sequence`, `plugin_instance` and `ended_tracks` keep their defaults: the
    # first two describe a wire and the process that wrote it (a sequence gap is
    # a line lost in a pipe, and there is no pipe), and the NIF mints no
    # identity to end — `plugins/cairn-native/src/lib.rs`, which returns an empty
    # `ended_tracks` for exactly that reason. `protocol` is `:v1` because that is
    # the distinction the field carries downstream: an observation that arrived
    # with its own epoch and its own time, so nothing has to fill either in.
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
  # milliseconds since 1970 (`plugins/cairn-native/src/stream.rs`) — the one
  # value arriving here that is not a time. Substituting the host's clock and
  # dropping to `:arrival` is what `Cairn.PluginPort` does with a timestamp it
  # will not date an event by.
  defp observed_at(unix_ms) do
    case DateTime.from_unix(unix_ms, :millisecond) do
      {:ok, at} -> {microsecond_precision(at), :source}
      {:error, _reason} -> {DateTime.utc_now(), :arrival}
    end
  end

  # Ecto refuses to dump a `:utc_datetime_usec` at any precision but 6
  # (`Ecto.Type.check_usec!` raises), and `Cairn.Tracks` writes track index rows
  # with `insert_all`, which dumps without casting. `Cairn.PluginProtocol` pads
  # the parsed timestamp for the same reason. The count of microseconds is
  # unchanged — only the declared precision moves.
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
  # `Cairn.Tracker.iou/2` scores it 0 against everything, so it would mint a
  # fresh identity every frame it appeared in — which is why `wire_bbox` declines
  # to emit one and `validate_det` refuses one. The guard is what makes the
  # clamp total, not a type check for its own sake.
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
