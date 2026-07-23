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
      "event #{metadata.event_id} (#{metadata.camera_id}): drained " <>
        "#{measurements.fragments} pre-window fragments (#{measurements.bytes} bytes)"
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
