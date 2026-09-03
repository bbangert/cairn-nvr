defmodule Cairn.Repo.Migrations.CanonicalizeCameraSettings do
  use Ecto.Migration

  # Rows written before `Cairn.Cameras.canonical/1` dropped these four can
  # hold values the parser reads exactly as it reads the absent key. They are
  # parse-identical, so nothing behaves differently — but they are not
  # byte-identical to what the editor writes now, so an untouched save would
  # diff and restart the camera for nothing (plan D-P5).
  #
  # Each removal is guarded by the shape it exists to remove: an unguarded
  # `json_remove` would also rewrite the rows that never held the key, and
  # `json_remove` reserializes the whole column when it does.
  def up do
    # `transcode` is true only when it is literally `true`; SQLite stores
    # JSON false as 0, and a string ("false", "no") reads false as well.
    execute """
    UPDATE cameras SET settings = json_remove(settings, '$.transcode')
    WHERE json_extract(settings, '$.transcode') = 0
       OR json_type(settings, '$.transcode') = 'text'
    """

    execute """
    UPDATE cameras SET settings = json_remove(settings, '$.pipeline')
    WHERE json_extract(settings, '$.pipeline') = 'membrane'
    """

    execute """
    UPDATE cameras SET settings = json_remove(settings, '$.extra_ffmpeg_args')
    WHERE json_type(settings, '$.extra_ffmpeg_args') = 'array'
      AND json_array_length(settings, '$.extra_ffmpeg_args') = 0
    """

    execute """
    UPDATE cameras SET settings = json_remove(settings, '$.min_score')
    WHERE json_type(settings, '$.min_score') = 'object'
      AND (SELECT count(*) FROM json_each(cameras.settings, '$.min_score')) = 0
    """
  end

  # Nothing to put back: the removed shapes parse identically to their
  # absence, so a downgrade reads the same config off the canonical rows.
  def down, do: :ok
end
