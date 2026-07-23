# Mock inference plugin — deterministic detection replay for tests/CI.
#
# Honors the plugin contract (docs/plugin-contract.md): config via argv,
# ndjson detections on stdout, logs on stderr. Ignores its UDP RTP input
# entirely; instead it replays a scripted timeline:
#
#     elixir mock_plugin.exs --camera-id cam --udp-port 17000 \
#       --min-score-json '{}' --timeline path/to/timeline.json [--loop]
#
# Timeline format (times relative to plugin start):
#
#     [{"at_ms": 100, "pts": 90000,
#       "dets": [{"label": "person", "score": 0.9, "bbox": [0.1,0.1,0.2,0.4]}]}]
{opts, _rest, _invalid} =
  OptionParser.parse(System.argv(),
    strict: [
      camera_id: :string,
      udp_port: :integer,
      min_score_json: :string,
      timeline: :string,
      loop: :boolean
    ]
  )

camera_id = Keyword.fetch!(opts, :camera_id)
timeline_path = Keyword.fetch!(opts, :timeline)

IO.puts(:stderr, "mock plugin up for #{camera_id}, udp #{opts[:udp_port]} (ignored)")

timeline =
  timeline_path
  |> File.read!()
  |> JSON.decode!()

emit = fn entries ->
  started = System.monotonic_time(:millisecond)

  for %{"at_ms" => at_ms, "pts" => pts, "dets" => dets} <- entries do
    delay = at_ms - (System.monotonic_time(:millisecond) - started)
    if delay > 0, do: Process.sleep(delay)
    IO.puts(JSON.encode!(%{"camera_id" => camera_id, "pts" => pts, "dets" => dets}))
  end
end

if opts[:loop] do
  Stream.repeatedly(fn -> emit.(timeline) end) |> Stream.run()
else
  emit.(timeline)
end
