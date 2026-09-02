import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :cairn, Cairn.Repo,
  database: Path.expand("../cairn_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# Tests use a fixed db path and a fixture YAML config; cameras (real
# ffmpeg processes) are never auto-started in tests
config :cairn,
  db_in_data_dir: false,
  config_path: "test/support/fixtures/configs/valid.yml",
  # Pinned to the file: a loader that imports the fixture into the DB at
  # boot would write rows outside the sandbox from a process no test owns
  # (boot-writes-escape-ecto-sandbox).
  config_loader: {Cairn.Config, :load_file},
  start_cameras: false,
  skip_boot_migrations: true,
  # The application's own `Cairn.TrackRecorder` buffers whatever any test's
  # camera tracker casts at it; without this its timer would flush those tracks
  # into whichever sandbox connection happens to be checked out at the time.
  track_recorder_manual: true

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :cairn, CairnWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "FMhbSHa4yyjkO18N0tQNrPx9fxTJG5BuRExs0A4amG4JXSA7jVd6BUpkR96WcKvM",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# The soak monitor writes under the configured data dir on a timer — test
# runs get no background writer (see boot-writes-escape-ecto-sandbox).
config :cairn, Cairn.SoakMonitor, enabled: false

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
