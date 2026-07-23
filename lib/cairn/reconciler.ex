defmodule Cairn.Reconciler do
  @moduledoc """
  Startup reconciliation between the event index and the filesystem —
  **disk is truth**. Runs before cameras start:

    * index rows whose clip file is missing -> delete the row
    * `active` rows with a file (crash mid-event) -> mark `partial`
    * orphaned mp4s with no row (filename encodes identity) -> adopt as
      `partial`
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
