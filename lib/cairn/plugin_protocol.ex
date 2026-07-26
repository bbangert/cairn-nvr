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

  @type det :: %{label: String.t(), score: float(), bbox: [number()]}

  @doc """
  Validates one raw detection map, normalizing `score` to a float.

  Valid iff `label` is a 1..#{@max_label_bytes}-byte binary, `score` is a
  number in 0..1, and `bbox` is exactly four numbers `[x, y, w, h]` with
  `x`/`y` in 0..1 and `w`/`h` in 0..1 and greater than zero.
  """
  @spec validate_det(term()) :: {:ok, det()} | :error
  def validate_det(%{"label" => label, "score" => score, "bbox" => bbox})
      when is_binary(label) and is_number(score) do
    if byte_size(label) in 1..@max_label_bytes and unit?(score) and valid_bbox?(bbox) do
      {:ok, %{label: label, score: score / 1, bbox: bbox}}
    else
      :error
    end
  end

  def validate_det(_other), do: :error

  @doc """
  Validates a list of raw detections, returning the valid ones in order
  together with how many were dropped.
  """
  @spec validate_dets([term()]) :: {[det()], non_neg_integer()}
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

  # Range comparisons also reject infinities and NaN, neither of which Jason
  # can produce but both of which would reach `Cairn.Tracker` arithmetic.
  defp valid_bbox?([x, y, w, h])
       when is_number(x) and is_number(y) and is_number(w) and is_number(h) do
    unit?(x) and unit?(y) and unit?(w) and unit?(h) and w > 0 and h > 0
  end

  defp valid_bbox?(_other), do: false

  defp unit?(n), do: n >= 0 and n <= 1
end
