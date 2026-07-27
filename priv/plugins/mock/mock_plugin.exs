# Mock inference plugin — deterministic detection replay for tests/CI.
#
# Honors the plugin contract (docs/plugin-contract.md): config via argv,
# ndjson on stdout, control lines on stdin, logs on stderr. Ignores its UDP
# RTP input entirely; instead it replays a scripted timeline. Both contract
# variants are supported:
#
#   per-camera (one process per camera):
#     elixir mock_plugin.exs --camera-id cam --udp-port 17000 \
#       --min-score-json '{}' --timeline path/to/timeline.json [--loop]
#
#   multiplexed (one process for N cameras):
#     elixir mock_plugin.exs --timeline path/to/timeline.json \
#       --cameras-json '[{"id": "cam", "udp_port": 17000, "min_score": {}}]'
#
# Timeline format (times relative to the first emission):
#
#     [{"at_ms": 100, "pts": 90000,
#       "dets": [{"label": "person", "score": 0.9, "bbox": [0.1,0.1,0.2,0.4]}]}]
#
# An entry may also carry "observed_at" (ISO8601, overriding "now"),
# "time_base" ([num, den]) and per-object "track_id"/"observation_kind".
# In multiplexed mode every timeline entry additionally carries the
# "camera_id" it belongs to, and each emitted line echoes that id.
#
# Protocol v1 is emitted by default: `plugin.hello`, `plugin.status`, then
# `frame.objects` lines stamped with the `stream_epoch` this plugin was told
# on stdin. `--v0` emits the original `{"pts", "dets"}` shape instead.
{opts, _rest, _invalid} =
  OptionParser.parse(System.argv(),
    strict: [
      camera_id: :string,
      udp_port: :integer,
      min_score_json: :string,
      cameras_json: :string,
      timeline: :string,
      loop: :boolean,
      hold: :boolean,
      v0: :boolean,
      epoch_wait_ms: :integer
    ]
  )

defmodule MockPlugin do
  @moduledoc false

  @spec emit(map()) :: :ok
  def emit(message), do: IO.puts(JSON.encode!(message))

  @table :mock_plugin_epochs
  @sequences :mock_plugin_sequences

  @doc "Public tables the stdin reader writes and the emitter reads."
  @spec new_tables() :: :ok
  def new_tables do
    :ets.new(@table, [:named_table, :public, :set])
    :ets.new(@sequences, [:named_table, :public, :set])
    :ok
  end

  @doc "Sequence numbers are per camera: the host tracks gaps per camera."
  @spec next_sequence(String.t()) :: pos_integer()
  def next_sequence(camera_id), do: :ets.update_counter(@sequences, camera_id, 1, {camera_id, 0})

  @spec epoch(String.t()) :: String.t()
  def epoch(camera_id) do
    case :ets.lookup(@table, camera_id) do
      [{^camera_id, epoch}] -> epoch
      [] -> "unknown"
    end
  end

  @doc "Reads control lines forever, recording the epoch of every stream.started."
  @spec read_control() :: :ok
  def read_control do
    case IO.read(:stdio, :line) do
      line when is_binary(line) ->
        record(JSON.decode(line))
        read_control()

      # :eof (stdin closed) or an error: nothing more will ever arrive, but
      # the plugin keeps running on whatever it was already told.
      _done ->
        :ok
    end
  end

  defp record({:ok, %{"type" => "stream.started"} = msg}) do
    with camera_id when is_binary(camera_id) <- msg["camera_id"],
         epoch when is_binary(epoch) <- msg["stream_epoch"] do
      IO.puts(:stderr, "mock plugin: stream.started #{camera_id} #{epoch}")
      :ets.insert(@table, {camera_id, epoch})
    end
  end

  defp record({:ok, %{"type" => "stream.ended"} = msg}) do
    with camera_id when is_binary(camera_id) <- msg["camera_id"] do
      IO.puts(:stderr, "mock plugin: stream.ended #{camera_id} (#{msg["reason"]})")
      :ets.delete(@table, camera_id)
    end
  end

  defp record(_other), do: :ok

  @doc """
  Waits until every camera has an epoch, or the deadline passes.

  Emitting before the host has announced the stream is legal but pointless:
  the epoch would not match and the host would drop the line.
  """
  @spec await_epochs([String.t()], integer()) :: :ok
  def await_epochs(_camera_ids, wait_ms) when wait_ms <= 0, do: :ok

  def await_epochs(camera_ids, wait_ms) do
    if Enum.all?(camera_ids, &(epoch(&1) != "unknown")) do
      :ok
    else
      Process.sleep(10)
      await_epochs(camera_ids, wait_ms - 10)
    end
  end
end

cameras =
  case opts[:cameras_json] do
    nil -> nil
    json -> JSON.decode!(json)
  end

camera_id = if cameras, do: nil, else: Keyword.fetch!(opts, :camera_id)
camera_ids = if cameras, do: Enum.map(cameras, & &1["id"]), else: [camera_id]
timeline_path = Keyword.fetch!(opts, :timeline)
v1? = !opts[:v0]

if cameras do
  members = Enum.map_join(cameras, ", ", &"#{&1["id"]}@#{&1["udp_port"]}")
  IO.puts(:stderr, "mock plugin up for #{length(cameras)} cameras: #{members} (udp ignored)")
else
  IO.puts(:stderr, "mock plugin up for #{camera_id}, udp #{opts[:udp_port]} (ignored)")
end

timeline =
  timeline_path
  |> File.read!()
  |> JSON.decode!()

MockPlugin.new_tables()
_reader = spawn_link(&MockPlugin.read_control/0)

if v1? do
  MockPlugin.emit(%{
    "spec" => "cairn.plugin",
    "version" => 1,
    "type" => "plugin.hello",
    "hello" => %{
      "name" => "mock",
      "version" => "1.0.0",
      "supported_versions" => [1],
      "capabilities" => %{"object_tracking" => false}
    }
  })

  MockPlugin.emit(%{
    "spec" => "cairn.plugin",
    "version" => 1,
    "type" => "plugin.status",
    "status" => %{"state" => "ready"}
  })

  MockPlugin.await_epochs(camera_ids, opts[:epoch_wait_ms] || 3_000)
end

emit = fn entries ->
  started = System.monotonic_time(:millisecond)

  for %{"at_ms" => at_ms, "pts" => pts, "dets" => dets} = entry <- entries do
    delay = at_ms - (System.monotonic_time(:millisecond) - started)
    if delay > 0, do: Process.sleep(delay)
    id = if cameras, do: Map.fetch!(entry, "camera_id"), else: camera_id

    if v1? do
      MockPlugin.emit(%{
        "spec" => "cairn.plugin",
        "version" => 1,
        "type" => "frame.objects",
        "camera_id" => id,
        "stream_epoch" => MockPlugin.epoch(id),
        "sequence" => MockPlugin.next_sequence(id),
        "frame" => %{
          "pts" => pts,
          "time_base" => Map.get(entry, "time_base", [1, 90_000]),
          "observed_at" =>
            Map.get(entry, "observed_at", DateTime.utc_now() |> DateTime.to_iso8601())
        },
        "objects" => dets
      })
    else
      MockPlugin.emit(%{"camera_id" => id, "pts" => pts, "dets" => dets})
    end
  end
end

cond do
  opts[:loop] ->
    Stream.repeatedly(fn -> emit.(timeline) end) |> Stream.run()

  opts[:hold] ->
    # emit once, then stay alive quietly — lets post-window finalization
    # happen without the Port respawning us into a fresh replay
    emit.(timeline)
    Process.sleep(:infinity)

  true ->
    emit.(timeline)
end
