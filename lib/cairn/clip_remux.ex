defmodule Cairn.ClipRemux do
  @moduledoc """
  Rewrites a finalized clip from concatenated fmp4 fragments into a plain mp4.

  Fragments arrive off the live stream carrying the camera's *absolute* decode
  times, and the init segment declares `empty_moov` — so `mvhd`/`mdhd` duration
  are both 0. With no declared length a player scans to the last fragment and
  reports that absolute time as the duration: a 60s event recorded two hours
  into a camera session probes as a two-hour file whose content sits at the
  very end, and seeking is meaningless. The error grows with camera uptime.

  `ffmpeg -c copy` rebases timestamps to zero and writes a real moov with
  sample tables (plus `+faststart`), which fixes duration and makes seeking
  exact. It re-reads and rewrites the clip once but never re-encodes, so it is
  lossless — the output is typically slightly *smaller* than the fragmented
  input. Disable with `remux_clips: false` to avoid that extra write at the
  cost of clips that misreport their length.

  ffmpeg runs under a hard timeout via a `/bin/sh exec` wrapper (same pattern
  as `Cairn.Probe`) so a hung encode can't wedge the calling extractor. Failure
  is non-fatal, matching `Cairn.Snapshot`: the fragmented original stays in
  place, still playable, just with the bogus duration.
  """

  require Logger

  @timeout_ms 60_000

  @doc """
  Remuxes `path` in place, returning the new byte size.

  `:error` means the clip was left untouched; callers should keep the size
  they already have.
  """
  @spec run(Path.t(), non_neg_integer()) :: {:ok, non_neg_integer()} | :error
  def run(path, timeout_ms \\ @timeout_ms) do
    tmp = path <> ".remux"

    argv =
      ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-i", path] ++
        ~w(-c copy -movflags +faststart -f mp4) ++ [tmp]

    case run_bounded(argv, timeout_ms) do
      :ok -> swap(path, tmp)
      {:error, reason} -> fail(path, tmp, reason)
    end
  rescue
    e -> fail(path, path <> ".remux", Exception.message(e))
  end

  # -- internals --------------------------------------------------------------

  # Spawn ffmpeg under `sh exec` so the kill on timeout reaches the real
  # process (a bare System.cmd exposes no pid to kill and no timeout). ffmpeg
  # writes to the temp file, not stdout, so we only wait on the exit status.
  defp run_bounded(argv, timeout_ms) do
    cmd = "exec " <> Enum.map_join(argv, " ", &shell_escape/1) <> " 2>&1"
    port = Port.open({:spawn_executable, "/bin/sh"}, [:binary, :exit_status, args: ["-c", cmd]])
    await_exit(port, os_pid(port), timeout_ms)
  end

  # `nil` when the port is already gone by the time we ask — a port opened with
  # `:exit_status` is torn down as the status is *queued*, not as it is read,
  # so a command that exits fast enough leaves nothing to inspect. That is not
  # a failure: the status is already in the mailbox for `await_exit/3`, and
  # there is no surviving process for the timeout branch to kill. Matching
  # `{:os_pid, _}` here instead turns it into a MatchError that costs the remux
  # for a clip ffmpeg had already rewritten correctly.
  defp os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> os_pid
      nil -> nil
    end
  end

  defp await_exit(port, os_pid, timeout_ms) do
    receive do
      {^port, {:data, _}} -> await_exit(port, os_pid, timeout_ms)
      {^port, {:exit_status, 0}} -> :ok
      {^port, {:exit_status, status}} -> {:error, "ffmpeg exited #{status}"}
    after
      timeout_ms ->
        if os_pid, do: System.cmd("kill", ["-KILL", "#{os_pid}"], stderr_to_stdout: true)
        safe_close(port)
        {:error, "ffmpeg timed out after #{timeout_ms}ms"}
    end
  end

  # Stat the temp file BEFORE renaming, so a stat failure can never leave the
  # file swapped-in while we report the old byte count. Refuse a zero-byte
  # output: exit 0 with a truncated file must not clobber the only good copy.
  defp swap(path, tmp) do
    with {:ok, %File.Stat{size: size}} when size > 0 <- File.stat(tmp),
         :ok <- File.rename(tmp, path) do
      {:ok, size}
    else
      {:ok, %File.Stat{size: 0}} -> fail(path, tmp, "remux produced an empty file")
      {:error, reason} -> fail(path, tmp, "swap failed: #{inspect(reason)}")
    end
  end

  defp fail(path, tmp, reason) do
    File.rm(tmp)

    Logger.warning(
      "clip remux failed for #{path}: #{sanitize(reason)} — keeping fragmented original"
    )

    :error
  end

  defp safe_close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp shell_escape(arg), do: "'" <> String.replace(arg, "'", "'\\''") <> "'"

  # Reason strings can carry ffmpeg stderr; strip control chars so a hostile
  # stream can't inject newlines/ANSI into the log, and cap the length.
  defp sanitize(reason) do
    reason |> to_string() |> String.replace(~r/[[:cntrl:]]/, " ") |> String.slice(0, 200)
  end
end
