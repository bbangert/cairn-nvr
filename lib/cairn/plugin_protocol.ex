defmodule Cairn.PluginProtocol do
  @moduledoc """
  Pure codec for the plugin wire protocol (see `docs/plugin-contract.md`).

  Plugin output is untrusted: a plugin is an arbitrary OS process and every
  decoded line reaches the singleton `Cairn.DetectionAggregator`, so a line
  that does not match the contract exactly must never leave this module.
  `Cairn.PluginPort` and `Cairn.PluginGroupPort` hand raw lines to
  `decode_line/2` and act on the result.

  Two wire versions are decoded here:

    * **v1** — a JSON object carrying `"spec": "cairn.plugin"` and
      `"version": 1`, with `frame.objects`, `plugin.hello` and
      `plugin.status` message types.
    * **v0** — the original untagged `{"pts": _, "dets": [_]}` line, still
      supported. It carries no epoch and no time, so the port completes the
      `Cairn.Observation` with arrival-quality timing.

  Forward compatibility is one-directional: unknown top-level fields and
  unknown `type` values are ignored, but a *malformed* known field drops the
  line. Nothing partially valid is forwarded.
  """

  alias Cairn.Observation

  @max_label_bytes 64
  # One cap for both wire versions: v1 `objects` and v0 `dets` are the same
  # per-frame list with the same cost downstream.
  @max_dets 64
  # `String.printable?/1` deliberately admits these; a detection label has no
  # use for them and a log line or a terminal does.
  @label_escapes ["\a", "\b", "\t", "\n", "\v", "\f", "\r", "\e"]
  @max_track_id_bytes 64
  @max_ended_tracks 64
  @max_camera_id_bytes 256
  @default_time_base {1, 90_000}
  @kinds ["detected", "tracked"]
  # v1 routing/versioning fields; anything else in a hello/status message is
  # the payload, for plugins that send it flat rather than nested.
  @envelope_keys ~w(spec version type camera_id stream_epoch sequence)

  @type det :: %{label: String.t(), score: float(), bbox: [number()]}

  @typedoc "Per-camera ports know their camera; group ports route by `camera_id`."
  @type mode :: :camera | :group

  @type decoded ::
          {:objects, Observation.t()}
          | {:hello, map()}
          | {:status, map()}
          | {:ignore, atom()}
          | {:error, atom()}

  @doc """
  Decodes one plugin stdout line.

  `mode` is `:group` for a multiplexed plugin — every `frame.objects` line
  must then name its camera. In `:camera` mode a `camera_id` is accepted and
  ignored: the port owns exactly one camera and attributes the line itself.

  `{:ignore, reason}` is a well-formed message this version does not act on
  (forward compatibility); `{:error, reason}` is a contract violation and the
  caller drops the line.
  """
  @spec decode_line(binary(), mode()) :: decoded()
  def decode_line(line, mode) when mode in [:camera, :group] do
    case Jason.decode(line) do
      {:ok, %{"spec" => "cairn.plugin"} = msg} -> decode_v1(msg, mode)
      {:ok, %{"spec" => _other}} -> {:error, :unknown_spec}
      {:ok, %{} = msg} -> decode_v0(msg, mode)
      {:ok, _other} -> {:error, :not_an_object}
      {:error, _reason} -> {:error, :malformed_json}
    end
  end

  # -- v1 ---------------------------------------------------------------------

  defp decode_v1(%{"version" => 1, "type" => type} = msg, mode) when is_binary(type) do
    case type do
      "frame.objects" -> decode_objects(msg, mode)
      "plugin.hello" -> {:hello, payload(msg, "hello")}
      "plugin.status" -> decode_status(msg)
      _other -> {:ignore, :unknown_type}
    end
  end

  defp decode_v1(%{"version" => version}, _mode) when version != 1,
    do: {:error, :unsupported_version}

  defp decode_v1(_msg, _mode), do: {:error, :invalid_envelope}

  defp decode_objects(msg, mode) do
    with {:ok, camera_id} <- camera_id(msg, mode),
         {:ok, epoch} <- fetch_string(msg, "stream_epoch", :invalid_stream_epoch),
         {:ok, sequence} <- sequence(msg),
         {:ok, frame} <- fetch_map(msg, "frame", :invalid_frame),
         {:ok, pts} <- fetch_number(frame, "pts", :invalid_pts),
         {:ok, time_base} <- time_base(frame),
         {:ok, observed_at} <- observed_at(frame),
         {:ok, objects, invalid} <- objects(msg),
         {:ok, ended_tracks} <- ended_tracks(msg) do
      {:objects,
       %Observation{
         camera_id: camera_id,
         epoch: epoch,
         sequence: sequence,
         pts: pts,
         time_base: time_base,
         media_ms: Observation.media_ms(pts, time_base),
         observed_at: observed_at,
         time_quality: :source,
         objects: objects,
         ended_tracks: ended_tracks,
         invalid_objects: invalid,
         protocol: :v1
       }}
    end
  end

  defp decode_status(msg) do
    payload = payload(msg, "status")

    cond do
      not is_binary(payload["state"]) ->
        {:error, :invalid_status}

      is_binary(msg["camera_id"]) ->
        {:status, Map.put(payload, "camera_id", msg["camera_id"])}

      true ->
        {:status, Map.delete(payload, "camera_id")}
    end
  end

  # A hello/status body may be nested under its type's key (canonical — it
  # keeps the plugin's own "version" clear of the protocol version) or sent
  # flat alongside the envelope.
  defp payload(msg, key) do
    case Map.get(msg, key) do
      %{} = nested -> nested
      _other -> Map.drop(msg, @envelope_keys)
    end
  end

  defp camera_id(msg, :group) do
    case Map.get(msg, "camera_id") do
      id when is_binary(id) and byte_size(id) in 1..@max_camera_id_bytes -> {:ok, id}
      _other -> {:error, :missing_camera_id}
    end
  end

  defp camera_id(msg, :camera) do
    case Map.get(msg, "camera_id") do
      id when is_binary(id) -> {:ok, id}
      _other -> {:ok, nil}
    end
  end

  defp sequence(msg) do
    case Map.get(msg, "sequence") do
      seq when is_integer(seq) and seq >= 0 -> {:ok, seq}
      _other -> {:error, :invalid_sequence}
    end
  end

  defp fetch_string(msg, key, error) do
    case Map.get(msg, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, error}
    end
  end

  defp fetch_map(msg, key, error) do
    case Map.get(msg, key) do
      %{} = value -> {:ok, value}
      _other -> {:error, error}
    end
  end

  defp fetch_number(msg, key, error) do
    case Map.get(msg, key) do
      value when is_number(value) -> {:ok, value}
      _other -> {:error, error}
    end
  end

  defp time_base(frame) do
    case Map.get(frame, "time_base", :absent) do
      :absent ->
        {:ok, @default_time_base}

      [num, den] when is_integer(num) and is_integer(den) and num > 0 and den > 0 ->
        {:ok, {num, den}}

      _other ->
        {:error, :invalid_time_base}
    end
  end

  defp observed_at(frame) do
    with value when is_binary(value) <- Map.get(frame, "observed_at"),
         {:ok, datetime, _offset} <- DateTime.from_iso8601(value) do
      {:ok, datetime}
    else
      _other -> {:error, :invalid_observed_at}
    end
  end

  defp objects(msg) do
    case Map.get(msg, "objects") do
      objects when is_list(objects) ->
        # One walk for the cap, as in `validate_dets/1`: an over-cap list is a
        # contract violation, and on v1 it drops the whole line.
        if length(objects) > @max_dets do
          {:error, :too_many_objects}
        else
          {valid, invalid} = validate_objects(objects)
          {:ok, valid, invalid}
        end

      _other ->
        {:error, :invalid_objects}
    end
  end

  defp validate_objects(objects) do
    {valid, invalid} =
      Enum.reduce(objects, {[], 0}, fn object, {valid, invalid} ->
        case validate_object(object) do
          {:ok, object} -> {[object | valid], invalid}
          :error -> {valid, invalid + 1}
        end
      end)

    {Enum.reverse(valid), invalid}
  end

  defp validate_object(object) do
    with {:ok, det} <- validate_det(object),
         {:ok, track_id} <- track_id(object),
         {:ok, kind} <- observation_kind(object) do
      {:ok, Map.merge(det, %{track_id: track_id, observation_kind: kind})}
    else
      _other -> :error
    end
  end

  defp track_id(%{"track_id" => id})
       when is_binary(id) and byte_size(id) in 1..@max_track_id_bytes,
       do: {:ok, id}

  defp track_id(%{"track_id" => _other}), do: :error
  defp track_id(_object), do: {:ok, nil}

  defp observation_kind(%{"observation_kind" => kind}) when kind in @kinds, do: {:ok, kind}
  defp observation_kind(%{"observation_kind" => _other}), do: :error
  defp observation_kind(_object), do: {:ok, "detected"}

  defp ended_tracks(msg) do
    case Map.get(msg, "ended_tracks", []) do
      ids when is_list(ids) and length(ids) <= @max_ended_tracks ->
        if Enum.all?(ids, &(is_binary(&1) and byte_size(&1) in 1..@max_track_id_bytes)) do
          {:ok, ids}
        else
          {:error, :invalid_ended_tracks}
        end

      _other ->
        {:error, :invalid_ended_tracks}
    end
  end

  # -- v0 ---------------------------------------------------------------------

  # No epoch and no timestamp on the wire: the port completes both, which is
  # why `time_quality` is `:arrival` for everything decoded here.
  defp decode_v0(%{"pts" => pts, "dets" => dets} = msg, mode)
       when is_number(pts) and is_list(dets) do
    with {:ok, camera_id} <- camera_id(msg, mode) do
      {objects, invalid} = validate_dets(dets)

      {:objects,
       %Observation{
         camera_id: camera_id,
         pts: pts,
         time_base: @default_time_base,
         media_ms: Observation.media_ms(pts, @default_time_base),
         time_quality: :arrival,
         objects:
           Enum.map(objects, &Map.merge(&1, %{track_id: nil, observation_kind: "detected"})),
         invalid_objects: invalid,
         protocol: :v0
       }}
    end
  end

  defp decode_v0(_msg, _mode), do: {:error, :missing_pts_or_dets}

  # -- detections -------------------------------------------------------------

  @doc """
  Validates one raw detection map, normalizing `score` to a float.

  Valid iff `label` is a printable 1..#{@max_label_bytes}-byte binary,
  `score` is a number in 0..1, and `bbox` is exactly four numbers
  `[x, y, w, h]` with `x`/`y` in 0..1 and `w`/`h` in 0..1 and greater than
  zero.

  "Printable" means `String.printable?/1` minus the escape characters it
  admits (`\\n`, `\\e`, …): it rejects NUL bytes, control characters, ANSI
  escapes and invalid UTF-8. Labels reach operator-facing output and
  `Cairn.Event` map keys, so a plugin must not be able to put terminal
  control bytes there.
  """
  @spec validate_det(term()) :: {:ok, det()} | :error
  def validate_det(%{"label" => label, "score" => score, "bbox" => bbox})
      when is_binary(label) and is_number(score) do
    if byte_size(label) in 1..@max_label_bytes and printable_label?(label) and unit?(score) and
         valid_bbox?(bbox) do
      {:ok, %{label: label, score: score / 1, bbox: bbox}}
    else
      :error
    end
  end

  def validate_det(_other), do: :error

  @doc """
  Validates a list of raw detections, returning the valid ones in order
  together with how many were dropped.

  A list longer than #{@max_dets} entries is a contract violation rather than
  a crowded frame: it is rejected whole (every entry counts as a drop). The
  cost of one batch in `Cairn.Tracker.track/2` is `O(dets × objects)` inside
  the singleton `Cairn.DetectionAggregator`, so an unbounded list wedges
  every camera's event tracking, not just this plugin's.

  Total on any term: a non-list counts as a single drop.
  """
  @spec validate_dets(term()) :: {[det()], non_neg_integer()}
  def validate_dets(dets) when is_list(dets) do
    count = length(dets)

    # An over-cap batch is still cast as an empty one, which is the plugin's
    # liveness signal.
    if count > @max_dets, do: {[], count}, else: reduce_dets(dets)
  end

  def validate_dets(_other), do: {[], 1}

  defp reduce_dets(dets) do
    {valid, dropped} =
      Enum.reduce(dets, {[], 0}, fn det, {valid, dropped} ->
        case validate_det(det) do
          {:ok, det} -> {[det | valid], dropped}
          :error -> {valid, dropped + 1}
        end
      end)

    {Enum.reverse(valid), dropped}
  end

  # Range comparisons also reject infinities and NaN, neither of which Jason
  # can produce but both of which would reach `Cairn.Tracker` arithmetic.
  defp valid_bbox?([x, y, w, h])
       when is_number(x) and is_number(y) and is_number(w) and is_number(h) do
    unit?(x) and unit?(y) and unit?(w) and unit?(h) and w > 0 and h > 0
  end

  defp valid_bbox?(_other), do: false

  defp printable_label?(label),
    do: String.printable?(label) and not String.contains?(label, @label_escapes)

  defp unit?(n), do: n >= 0 and n <= 1
end
