defmodule Cairn.PluginProtocol do
  @moduledoc """
  Validation and codec for the plugin wire protocol (see
  `docs/plugin-contract.md`).

  Plugin output is untrusted: a plugin is an arbitrary OS process and every
  decoded line reaches the singleton `Cairn.DetectionAggregator`, so a
  detection that does not match the contract exactly must never leave this
  module. `Cairn.PluginPort` and `Cairn.PluginGroupPort` decode the JSON
  framing and hand the raw values here.
  """

  @max_label_bytes 64
  @max_dets 64
  # `String.printable?/1` deliberately admits these; a detection label has no
  # use for them and a log line or a terminal does.
  @label_escapes ["\a", "\b", "\t", "\n", "\v", "\f", "\r", "\e"]

  @type det :: %{label: String.t(), score: float(), bbox: [number()]}

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
  def validate_dets(dets) when is_list(dets) and length(dets) > @max_dets do
    # The caller still casts the empty batch, which is the plugin's liveness signal.
    {[], length(dets)}
  end

  def validate_dets(dets) when is_list(dets) do
    {valid, dropped} =
      Enum.reduce(dets, {[], 0}, fn det, {valid, dropped} ->
        case validate_det(det) do
          {:ok, det} -> {[det | valid], dropped}
          :error -> {valid, dropped + 1}
        end
      end)

    {Enum.reverse(valid), dropped}
  end

  def validate_dets(_other), do: {[], 1}

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
