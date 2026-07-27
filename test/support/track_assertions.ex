defmodule Cairn.TrackAssertions do
  @moduledoc """
  One shared assertion for the ONVIF AN §A.10 obligation on `Cairn.Track`
  finals: the summary stands on its own.

  Kept in one place on purpose — asserted ad hoc, each end path (`:unseen`,
  `:plugin_ended`, `:stream_reset`, `:evicted`, `:detection_disabled`,
  `:host_restart`) grows its own list of checked fields and a regression that
  nils one of them on a single path goes unnoticed.
  """

  import ExUnit.Assertions

  alias Cairn.Track

  # `epoch` is absent from this list deliberately: a v0 observation before the
  # first ffmpeg spawn genuinely has none. `plugin_track_id` is checked only
  # for a plugin-owned track, where it is the plugin's half of the identity.
  @required [
    :object_id,
    :camera_id,
    :label,
    :score,
    :best_score,
    :bbox,
    :source,
    :started_at,
    :last_seen_at,
    :end_reason
  ]

  @doc "Asserts a final `%Cairn.Track{}` carries everything a consumer needs."
  @spec assert_self_contained(Track.t()) :: Track.t()
  def assert_self_contained(%Track{} = track) do
    for field <- @required do
      refute is_nil(Map.fetch!(track, field)), "final summary is missing #{field}"
    end

    assert is_boolean(track.stale_predicted)

    if track.source == :plugin do
      refute is_nil(track.plugin_track_id), "a plugin-owned final is missing plugin_track_id"
    end

    track
  end
end
