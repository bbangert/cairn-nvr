# The full-pipeline integration test needs ffmpeg + several seconds of
# realtime streaming; run it explicitly with: mix test --include integration
ExUnit.start(exclude: [:integration])
Ecto.Adapters.SQL.Sandbox.mode(Cairn.Repo, :manual)
