# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :cairn,
  ecto_repos: [Cairn.Repo],
  generators: [timestamp_type: :utc_datetime],
  # the SQLite db lives at {data_dir}/cairn.db unless a config env disables it
  db_in_data_dir: true,
  # Where `Cairn.Config.Server` loads from: a 1-arity fun of the config path,
  # or `{module, function}` naming one. dev and prod override this with
  # `Cairn.ConfigSource`; test and this base keep the file.
  config_loader: {Cairn.Config, :load_file}

config :cairn, Cairn.Repo,
  busy_timeout: 5_000,
  pool_size: 2

# Configure the endpoint
config :cairn, CairnWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: CairnWeb.ErrorHTML, json: CairnWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Cairn.PubSub,
  live_view: [signing_salt: "Y0FoGp0/"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  cairn: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  cairn: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Keep credentialed values out of request logs; the default list only
# covers "password". "access_token" is the HA integration token, accepted
# as `?access_token=` on media URLs; "token" and "sdp" cover the WebRTC
# signaling params. "rtsp_url" and "substream_url" are the two camera-form
# params that can carry a full `rtsp://user:pass@host/...` URL — one for
# each stream a camera can configure; "extra_ffmpeg_args" is operator argv
# that may carry a header or a second credentialed URL.
config :phoenix, :filter_parameters, [
  "password",
  "access_token",
  "token",
  "sdp",
  "rtsp_url",
  "substream_url",
  "extra_ffmpeg_args"
]

# Extra MIME types the HA `/api` surface negotiates: SSE for the event feed
# and SDP for the WHEP WebRTC offer/answer. Registering them lets the `:api`
# pipeline's `:accepts` allow these formats.
config :mime, :types, %{
  "text/event-stream" => ["sse"],
  "application/sdp" => ["sdp"]
}

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
