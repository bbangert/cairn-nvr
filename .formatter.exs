[
  import_deps: [:ecto, :ecto_sql, :phoenix, :membrane_core],
  subdirectories: ["priv/*/migrations"],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  inputs: [
    "*.{heex,ex,exs}",
    ".argus-baseline.exs",
    "{config,lib,test,scripts}/**/*.{heex,ex,exs}",
    "priv/*/seeds.exs"
  ]
]
