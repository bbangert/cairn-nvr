defmodule Cairn.Reconciler do
  @moduledoc """
  Startup reconciliation between the event index and the filesystem —
  **disk is truth**. Runs before cameras start:

    * index rows whose clip file is missing -> delete the row
    * `active` rows with a file (crash mid-event) -> mark `partial`
    * orphaned mp4s with no row (filename encodes identity) -> adopt as
      `partial`

  A row whose `Cairn.EventExtractor` is still registered is skipped: disk is
  truth only for files nobody is writing. It cannot happen on a clean boot
  (cameras start after this runs), but `Cairn.Boot` is `:transient` — a later
  failure in one of its sync steps re-runs the whole task with extractors
  live, and deleting a row out from under one turns a healthy clip into a
  false `event_clip_failed{reason: :not_found}`.
  """

  require Logger

  alias Cairn.{DataDir, Events}

  @spec run(Cairn.Config.t()) :: %{
          deleted: non_neg_integer(),
          partialed: non_neg_integer(),
          adopted: non_neg_integer()
        }
  def run(config) do
    rows = Events.all()

    {deleted, partialed} =
      Enum.reduce(rows, {0, 0}, fn row, {deleted, partialed} ->
        cond do
          recording?(row) ->
            {deleted, partialed}

          is_nil(row.path) or not File.exists?(row.path) ->
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

    summary = %{deleted: deleted, partialed: partialed, adopted: adopted}

    if deleted + partialed + adopted > 0 do
      Logger.info(
        "reconciliation: #{deleted} rows deleted (missing files), " <>
          "#{partialed} active rows marked partial, #{adopted} orphan clips adopted"
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
