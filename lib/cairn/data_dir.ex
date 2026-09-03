defmodule Cairn.DataDir do
  @moduledoc """
  Resolves the data directory and ensures its subdirectory layout exists:
  `events/`, `snapshots/`, `log/`. All mutable state lives under this root.
  """

  require Logger

  @subdirs ~w(events snapshots log)

  @doc """
  Creates the data dir and its subdirs, raising when one cannot be created —
  a boot the node has no business continuing. Tightening permissions is a
  second, best-effort pass: the dir and its log dir go to 0700 and the DB
  files to 0600, and a chmod the volume refuses (a restored backup under
  another uid, a bind mount) is logged and left as is rather than made a
  reason to crash-loop the boot.
  """
  @spec ensure!(Path.t()) :: :ok
  def ensure!(data_dir) do
    File.mkdir_p!(data_dir)
    chmod(data_dir, 0o700)
    Enum.each(Enum.map(@subdirs, &Path.join(data_dir, &1)), &File.mkdir_p!/1)
    # ffmpeg/plugin logs can echo credentialed URLs — keep them private
    chmod(log_dir(data_dir), 0o700)
    secure_db(data_dir)
    :ok
  end

  @doc """
  Tightens `cairn.db` and its WAL/SHM siblings to 0600 wherever they already
  exist — the DB holds camera rows with RTSP userinfo, so it gets the same
  treatment as the log dir. Never creates a file; a missing one is skipped,
  not an error. Never raises: a chmod an operator's restored backup or
  volume permissions refuse (EPERM) is logged and left as is, not a reason
  to crash-loop the boot.
  """
  @spec secure_db(Path.t()) :: :ok
  def secure_db(data_dir) do
    db = db_path(data_dir)

    Enum.each([db, db <> "-wal", db <> "-shm"], &(File.exists?(&1) and chmod(&1, 0o600)))
    :ok
  end

  defp chmod(path, mode) do
    case File.chmod(path, mode) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "could not chmod #{path} to #{Integer.to_string(mode, 8)}: #{:file.format_error(reason)}"
        )

        :ok
    end
  end

  @spec events_dir(Path.t(), String.t()) :: Path.t()
  def events_dir(data_dir, camera_id), do: Path.join([data_dir, "events", camera_id])

  @spec snapshots_dir(Path.t()) :: Path.t()
  def snapshots_dir(data_dir), do: Path.join(data_dir, "snapshots")

  @spec log_dir(Path.t()) :: Path.t()
  def log_dir(data_dir), do: Path.join(data_dir, "log")

  @spec db_path(Path.t()) :: Path.t()
  def db_path(data_dir), do: Path.join(data_dir, "cairn.db")

  @doc "Clip path encoding identity for index rebuild."
  @spec event_clip_path(Path.t(), String.t(), String.t(), integer()) :: Path.t()
  def event_clip_path(data_dir, camera_id, event_id, unix_ts) do
    Path.join(events_dir(data_dir, camera_id), "#{event_id}_#{camera_id}_#{unix_ts}.mp4")
  end

  @doc """
  The `Cairn.TrackPath` sidecar path for a clip: the same name with `.tracks`
  in place of `.mp4`.

  Derived rather than stored in an index column, which is what keeps
  `Cairn.Reconciler`'s orphan adoption (adopt_orphans/2) working unchanged — an
  event adopted from a clip file the index never knew about finds its sidecar
  by the same derivation, with nothing to look up and no column left dangling
  at a file that was pruned.
  """
  @spec trackpath_for_clip(Path.t()) :: Path.t()
  def trackpath_for_clip(clip_path), do: Path.rootname(clip_path, ".mp4") <> ".tracks"

  @doc """
  Parses an event clip filename back into its identity parts.
  Returns `{:ok, event_id, camera_id, unix_ts}` or `:error`.
  """
  @spec parse_clip_filename(String.t()) :: {:ok, String.t(), String.t(), integer()} | :error
  def parse_clip_filename(filename) do
    with base when base != filename <- Path.basename(filename, ".mp4"),
         [event_id, rest] <- String.split(base, "_", parts: 2),
         [camera_id, ts] <- split_camera_ts(rest),
         {unix_ts, ""} <- Integer.parse(ts) do
      {:ok, event_id, camera_id, unix_ts}
    else
      _ -> :error
    end
  end

  # camera ids may contain underscores; the timestamp is the last segment
  defp split_camera_ts(rest) do
    case String.split(rest, "_") do
      parts when length(parts) >= 2 ->
        {ts, camera_parts} = List.pop_at(parts, -1)
        [Enum.join(camera_parts, "_"), ts]

      _ ->
        :error
    end
  end
end
