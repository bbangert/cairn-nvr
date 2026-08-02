defmodule Cairn.Reconciler do
  @moduledoc """
  Startup reconciliation between the event index and the filesystem —
  **disk is truth**. Runs before cameras start:

    * index rows whose clip file is missing -> delete the row and the
      `Cairn.TrackPath` sidecar derived from its clip path
    * `active` rows with a file (crash mid-event) -> mark `partial`
    * orphaned mp4s with no row (filename encodes identity) -> adopt as
      `partial`

  A row whose `Cairn.EventExtractor` is still registered is skipped: disk is
  truth only for files nobody is writing. It cannot happen on a clean boot
  (cameras start after this runs), but `Cairn.Boot` is `:transient` — a later
  failure in one of its sync steps re-runs the whole task with extractors
  live, and deleting a row out from under one turns a healthy clip into a
  false `event_clip_failed{reason: :not_found}`.

  The track index gets the same treatment on the way past, for the same reason
  the event index does — nothing that could still be writing those rows is
  running yet. A track row is open while its track is live and only its own
  writer ever closes it, so the ones left open here belong to a host that is
  gone: `Cairn.Tracks.close_live/0` closes them as `:host_restart`, which is
  what a track that outlives its host ended as.
  """

  require Logger

  alias Cairn.{DataDir, Events, Tracks}

  @spec run(Cairn.Config.t()) :: %{
          deleted: non_neg_integer(),
          partialed: non_neg_integer(),
          adopted: non_neg_integer(),
          tracks_closed: non_neg_integer()
        }
  def run(config) do
    rows = Events.all()

    {deleted, partialed} =
      Enum.reduce(rows, {0, 0}, fn row, {deleted, partialed} ->
        cond do
          recording?(row) ->
            {deleted, partialed}

          is_nil(row.path) or not File.exists?(row.path) ->
            # `delete_row/1` is the index alone; this is the one caller that
            # reaches it without going through `Events.delete/1`, so the
            # derived sidecar has to be shed here or nothing ever collects it —
            # `adopt_orphans/2` globs `*.mp4`, and no row is left to name the
            # file. `File.rm/1`'s error is discarded exactly as it is there.
            if row.path, do: File.rm(DataDir.trackpath_for_clip(row.path))
            Events.delete_row(row)
            {deleted + 1, partialed}

          row.status == :active ->
            Events.mark_partial(row.id, %{bytes: file_size(row.path)})
            {deleted, partialed + 1}

          true ->
            {deleted, partialed}
        end
      end)

    known_ids = MapSet.new(rows, & &1.id)
    adopted = adopt_orphans(config, known_ids)

    # Deliberately not coordinated with the camera trackers' checkpoint restore,
    # which closes the tracks of cameras that had an open event. That restore is
    # kicked off before `Cairn.Boot` (`Cairn.TrackerSupervisor` and its sweep are
    # earlier children) but runs in a task of its own, and it hands its closes to
    # `Cairn.TrackRecorder`, which writes them a flush interval later — so either
    # write can reach the table first. Both say
    # `:host_restart` and track rows upsert, so whichever lands second wins and
    # the only thing at stake is `ended_at`: the restore's `last_seen_at` (the
    # track's own last observation) against the `updated_at` this derives from,
    # which is the same instant give or take a flush interval.
    tracks_closed = Tracks.close_live()

    summary = %{
      deleted: deleted,
      partialed: partialed,
      adopted: adopted,
      tracks_closed: tracks_closed
    }

    if deleted + partialed + adopted + tracks_closed > 0 do
      Logger.info(
        "reconciliation: #{deleted} rows deleted (missing files), " <>
          "#{partialed} active rows marked partial, #{adopted} orphan clips adopted, " <>
          "#{tracks_closed} live track rows closed"
      )
    end

    summary
  end

  # An extractor still holds this row's file open and will finalize it itself.
  #
  # A registry entry outlives its process briefly, so this can read a dead
  # extractor as live — safe here, and deliberately not waited out: a stale
  # read errs toward *inaction* (the row is left active rather than wrongly
  # marked partial), and the next boot's reconcile catches it. `run/1` is
  # called once, from `Cairn.Boot`; there is no periodic reconcile to
  # self-correct, so the conservative direction is the whole guarantee.
  defp recording?(row) do
    Cairn.Registry.whereis(row.camera_id, {:extractor, row.id}) != nil
  end

  defp adopt_orphans(config, known_ids) do
    [config.data_dir, "events", "*", "*.mp4"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.count(fn path ->
      case DataDir.parse_clip_filename(path) do
        {:ok, event_id, camera_id, unix_ts} ->
          maybe_adopt(known_ids, event_id, camera_id, unix_ts, path)

        :error ->
          Logger.warning("reconciliation: unparseable clip filename #{path}, skipping")
          false
      end
    end)
  end

  defp maybe_adopt(known_ids, event_id, camera_id, unix_ts, path) do
    if MapSet.member?(known_ids, event_id) do
      false
    else
      adopt(event_id, camera_id, unix_ts, path)
    end
  end

  defp adopt(event_id, camera_id, unix_ts, path) do
    started_at = DateTime.from_unix!(unix_ts)

    case Events.adopt_orphan(event_id, camera_id, started_at, path, file_size(path)) do
      {:ok, _} ->
        true

      {:error, reason} ->
        Logger.warning("reconciliation: could not adopt #{path}: #{inspect(reason)}")
        false
    end
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end
end
