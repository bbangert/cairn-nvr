defmodule Cairn.Snapshot do
  @moduledoc """
  Per-event snapshot: first keyframe of the clip as
  `snapshots/{event_id}.jpg`, extracted async post-finalize. Failure is
  non-fatal (log only) — the UI falls back to a placeholder.
  """

  require Logger

  @spec take_async(Cairn.Events.Event.t(), Cairn.Config.t()) :: {:ok, pid()}
  def take_async(row, config) do
    Task.Supervisor.start_child(Cairn.TaskSupervisor, fn -> take(row, config) end)
  end

  @spec take(Cairn.Events.Event.t(), Cairn.Config.t()) :: :ok
  def take(row, config) do
    out = Path.join(Cairn.DataDir.snapshots_dir(config.data_dir), "#{row.id}.jpg")

    args =
      ["-y", "-hide_banner", "-loglevel", "error", "-i", row.path] ++
        ~w(-frames:v 1 -q:v 4) ++ [out]

    case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
      {_out, 0} ->
        Cairn.Events.set_snapshot(row.id, out)
        :ok

      {output, status} ->
        Logger.warning(
          "event #{row.id}: snapshot failed (#{status}): #{String.slice(output, 0, 200)}"
        )

        :ok
    end
  rescue
    e ->
      Logger.warning("event #{row.id}: snapshot error: #{Exception.message(e)}")
      :ok
  end
end
