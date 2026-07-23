import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/cairn start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :cairn, CairnWeb.Endpoint, server: true
end

config :cairn, CairnWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :cairn, CairnWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/cairn_web/router\.ex$"E,
        ~r"lib/cairn_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  # All state lives under CAIRN_DATA_DIR ({data_dir}/cairn.db included);
  # the YAML config comes from CAIRN_CONFIG. Both are read by the app at
  # boot (Cairn.Config); the db path is derived via Repo.init/2
  # (db_in_data_dir, see config.exs). Nothing else is required.

  # The secret key base signs LiveView sessions. Cairn has no accounts or
  # secrets of its own (LAN-trusted, no auth in v1), so a generated one is
  # created under the data dir when not provided explicitly.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      Cairn.ReleaseSecrets.ensure_secret_key_base!()

  host = System.get_env("PHX_HOST") || "localhost"

  config :cairn, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :cairn, CairnWeb.Endpoint,
    url: [host: host, port: String.to_integer(System.get_env("PORT", "4000"))],
    http: [
      # LAN deployment: bind all interfaces (dual-stack)
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :cairn, CairnWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :cairn, CairnWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
