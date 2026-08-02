defmodule Cairn.ExtractorTelemetry do
  @moduledoc """
  Logger handler for `[:cairn, :extractor, :drained | :finalized]`
  telemetry — one summary line per event write.
  """

  require Logger

  @events [[:cairn, :extractor, :drained], [:cairn, :extractor, :finalized]]

  @spec attach() :: :ok
  def attach do
    :telemetry.attach_many("cairn-extractor-logger", @events, &__MODULE__.handle_event/4, nil)
  end

  @doc false
  def handle_event([:cairn, :extractor, :drained], measurements, metadata, _config) do
    Logger.debug(
      "event #{metadata.event_id} (#{metadata.camera_id}): kept " <>
        "#{measurements.fragments} pre-window fragments (#{measurements.bytes} bytes), " <>
        "skipped #{measurements.skipped} before the first keyframe"
    )
  end

  # Zero fragments is the event no keyframe ever reached: the bytes are an init
  # segment and nothing else, and `Cairn.EventExtractor` announced it as a
  # failed clip. A line saying "clip written" is the same false success the
  # broadcast is careful not to be.
  def handle_event([:cairn, :extractor, :finalized], %{fragments: 0} = measurements, metadata, _c) do
    Logger.info(
      "event #{metadata.event_id} (#{metadata.camera_id}): no clip written — " <>
        "no keyframe arrived in #{measurements.write_duration_ms}ms"
    )
  end

  def handle_event([:cairn, :extractor, :finalized], measurements, metadata, _config) do
    Logger.info(
      "event #{metadata.event_id} (#{metadata.camera_id}): clip written — " <>
        "#{measurements.bytes} bytes, #{measurements.fragments} fragments, " <>
        "#{measurements.write_duration_ms}ms"
    )
  end
end
