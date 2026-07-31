# The test data_dir is shared across runs; boot-time reconciliation will
# have adopted any clips a previous run left behind (committed outside the
# sandbox). Start every run from a clean slate.
File.rm_rf!("tmp/cairn_test_data/events")
File.rm_rf!("tmp/cairn_test_data/snapshots")
Cairn.DataDir.ensure!("tmp/cairn_test_data")
Cairn.Repo.delete_all(Cairn.Events.Event)
# Child first, stated rather than relied upon: the cascade would cover the
# moments, but writing the order down keeps a later reorder from turning into a
# foreign-key error.
Cairn.Repo.delete_all(Cairn.Tracks.TrackEvent)
Cairn.Repo.delete_all(Cairn.Tracks.Track)

# The full-pipeline integration test needs ffmpeg + several seconds of
# realtime streaming; run it explicitly with: mix test --include integration
ExUnit.start(exclude: [:integration])
Ecto.Adapters.SQL.Sandbox.mode(Cairn.Repo, :manual)
