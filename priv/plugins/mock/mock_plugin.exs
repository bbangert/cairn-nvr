# Mock inference plugin — deterministic detection replay for tests/CI.
#
# Honors the plugin contract (docs/plugin-contract.md): config via argv,
# ndjson detections on stdout, logs on stderr. Ignores its UDP RTP input
# entirely; instead it replays a scripted timeline. Both contract variants
# are supported:
#
#   per-camera (one process per camera):
#     elixir mock_plugin.exs --camera-id cam --udp-port 17000 \
#       --min-score-json '{}' --timeline path/to/timeline.json [--loop]
#
#   multiplexed (one process for N cameras):
#     elixir mock_plugin.exs --timeline path/to/timeline.json \
#       --cameras-json '[{"id": "cam", "udp_port": 17000, "min_score": {}}]'
#
# Timeline format (times relative to plugin start):
#
#     [{"at_ms": 100, "pts": 90000,
#       "dets": [{"label": "person", "score": 0.9, "bbox": [0.1,0.1,0.2,0.4]}]}]
#
# In multiplexed mode every timeline entry additionally carries the
# "camera_id" it belongs to, and each emitted line echoes that id.
{opts, _rest, _invalid} =
  OptionParser.parse(System.argv(),
    strict: [
      camera_id: :string,
      udp_port: :integer,
      min_score_json: :string,
      cameras_json: :string,
      timeline: :string,
      loop: :boolean,
      hold: :boolean
    ]
  )

cameras =
  case opts[:cameras_json] do
    nil -> nil
    json -> JSON.decode!(json)
  end

camera_id = if cameras, do: nil, else: Keyword.fetch!(opts, :camera_id)
timeline_path = Keyword.fetch!(opts, :timeline)

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

emit = fn entries ->
  started = System.monotonic_time(:millisecond)

  for %{"at_ms" => at_ms, "pts" => pts, "dets" => dets} = entry <- entries do
    delay = at_ms - (System.monotonic_time(:millisecond) - started)
    if delay > 0, do: Process.sleep(delay)
    id = if cameras, do: Map.fetch!(entry, "camera_id"), else: camera_id
    IO.puts(JSON.encode!(%{"camera_id" => id, "pts" => pts, "dets" => dets}))
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
