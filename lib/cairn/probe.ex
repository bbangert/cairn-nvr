defmodule Cairn.Probe do
  @moduledoc """
  Camera stream probe: `ffprobe -show_streams -show_format -of json` with a
  hard timeout (sh `exec` wrapper so the kill reaches the real ffprobe).

  Runs on camera start and on config reload; the parsed result
  (codec/resolution/fps/profile + an optional warning for non-H.264
  sources) is stored in `Cairn.CameraStatus` for the config page and
  dashboard badges.
  """

  @timeout_ms 15_000

  @doc "Probes the camera and stores the result in `Cairn.CameraStatus`."
  @spec run_and_store(Cairn.Config.Camera.t()) :: :ok
  def run_and_store(cam) do
    result =
      case run(cam.rtsp_url) do
        {:ok, probe} -> annotate(probe, cam)
        {:error, reason} -> %{error: format_error(reason)}
      end

    Cairn.CameraStatus.set_probe(cam.id, result)
    :ok
  end

  @spec run(String.t(), non_neg_integer()) :: {:ok, map()} | {:error, term()}
  def run(url, timeout_ms \\ @timeout_ms) do
    argv =
      ["ffprobe", "-v", "error"] ++
        transport_opts(url) ++
        ["-show_streams", "-show_format", "-of", "json", url]

    cmd = "exec " <> Enum.map_join(argv, " ", &shell_escape/1) <> " 2>/dev/null"

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [:binary, :exit_status, args: ["-c", cmd]])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    collect(port, os_pid, <<>>, timeout_ms)
  end

  @doc "Parses ffprobe JSON output into the probe map. Pure."
  @spec parse(binary()) :: {:ok, map()} | {:error, term()}
  def parse(json) do
    with {:ok, %{"streams" => streams}} <- Jason.decode(json),
         %{} = video <- Enum.find(streams, &(&1["codec_type"] == "video")) do
      {:ok,
       %{
         codec: video["codec_name"],
         width: video["width"],
         height: video["height"],
         fps: parse_fps(video["avg_frame_rate"] || video["r_frame_rate"]),
         profile: video["profile"]
       }}
    else
      nil -> {:error, :no_video_stream}
      {:error, _} = error -> error
      _ -> {:error, :unexpected_output}
    end
  end

  # -- internals --------------------------------------------------------------

  defp collect(port, os_pid, acc, timeout_ms) do
    started = System.monotonic_time(:millisecond)

    receive do
      {^port, {:data, data}} ->
        elapsed = System.monotonic_time(:millisecond) - started
        collect(port, os_pid, acc <> data, max(timeout_ms - elapsed, 0))

      {^port, {:exit_status, 0}} ->
        parse(acc)

      {^port, {:exit_status, status}} ->
        {:error, {:ffprobe_exit, status}}
    after
      timeout_ms ->
        System.cmd("kill", ["-KILL", "#{os_pid}"], stderr_to_stdout: true)
        safe_close(port)
        {:error, :timeout}
    end
  end

  defp safe_close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp transport_opts("rtsp://" <> _), do: ["-rtsp_transport", "tcp"]
  defp transport_opts(_other), do: []

  defp parse_fps(nil), do: nil

  defp parse_fps(rate) do
    case String.split(rate, "/") do
      [n, "0"] ->
        case Float.parse(n) do
          {_n, _} -> nil
          :error -> nil
        end

      [n, d] ->
        with {n, ""} <- Integer.parse(n),
             {d, ""} <- Integer.parse(d) do
          Float.round(n / d, 2)
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp annotate(%{codec: "h264"} = probe, _cam), do: probe

  defp annotate(probe, %{transcode: true}), do: probe

  defp annotate(probe, _cam) do
    Map.put(
      probe,
      :warning,
      "stream is #{probe.codec || "unknown"}, not H.264 — switch the camera to H.264 " <>
        "or enable transcode"
    )
  end

  defp format_error(:timeout), do: "probe timed out"
  defp format_error(reason), do: "probe failed: #{inspect(reason)}"

  defp shell_escape(arg), do: "'" <> String.replace(arg, "'", "'\\''") <> "'"
end
