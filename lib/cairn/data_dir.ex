defmodule Cairn.DataDir do
  @moduledoc """
  Resolves the data directory and ensures its subdirectory layout exists:
  `events/`, `snapshots/`, `log/`. All mutable state lives under this root.
  """

  @subdirs ~w(events snapshots log)

  @doc "Creates the data dir and its subdirs. Raises on failure."
  @spec ensure!(Path.t()) :: :ok
  def ensure!(data_dir) do
    Enum.each([data_dir | Enum.map(@subdirs, &Path.join(data_dir, &1))], &File.mkdir_p!/1)
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
