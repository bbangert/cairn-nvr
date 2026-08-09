# The test data_dir is shared across runs; boot-time reconciliation will
# have adopted any clips a previous run left behind (committed outside the
# sandbox). Start every run from a clean slate.
File.rm_rf!("tmp/cairn_test_data/events")
File.rm_rf!("tmp/cairn_test_data/snapshots")
Cairn.DataDir.ensure!("tmp/cairn_test_data")
Cairn.Repo.delete_all(Cairn.Events.Event)
# Child first so this cleanup works whatever the cascade or the connection's
# `PRAGMA foreign_keys` happens to be — no order here can raise (deleting
# parents first would just cascade), but only this one depends on neither.
Cairn.Repo.delete_all(Cairn.Tracks.TrackEvent)
Cairn.Repo.delete_all(Cairn.Tracks.Track)

# The full-pipeline integration test needs ffmpeg + several seconds of
# realtime streaming; run it explicitly with: mix test --include integration
#
# :native_parity needs more than that — the `cairn-native` NIF in priv/native,
# the `cairn-detect` release binary, a model and recorded clips, none of which
# the Elixir CI job builds or carries. Run it with: mix test --only native_parity
#
# :e2e_membrane needs everything :native_parity does *and* everything
# :integration does — it runs the whole membrane stack on a recorded clip.
# Run it with: mix test --only e2e_membrane
ExUnit.start(exclude: [:integration, :native_parity, :e2e_membrane])
Ecto.Adapters.SQL.Sandbox.mode(Cairn.Repo, :manual)
