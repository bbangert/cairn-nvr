defmodule Cairn.MixProject do
  use Mix.Project

  def project do
    [
      app: :cairn,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_core_path: "priv/plts",
        plt_local_path: "priv/plts"
      ],
      releases: [
        cairn: [
          include_executables_for: [:unix],
          applications: [runtime_tools: :permanent]
        ]
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Cairn.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test, check: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.9"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.9.0"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:daisyui,
       github: "saadeghi/daisyui",
       tag: "v5.7.16",
       sparse: "packages/bundle",
       app: false,
       compile: false,
       depth: 1},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:msgpax, "~> 2.4"},
      {:dns_cluster, "~> 0.3.0"},
      {:bandit, "~> 1.5"},
      {:yaml_elixir, "~> 2.11"},
      {:ex_webrtc, "~> 0.17.0"},
      # Membrane pipeline (all Apache-2.0)
      {:membrane_core, "~> 1.3.4"},
      # membrane_core → ratio 4.0.1 caps its *optional* decimal dep at ~> 2.0
      # (ratio only defines Coerce protocols over Decimal), while ecto_sqlite3
      # requires ~> 3.0. Override until ratio lifts the cap.
      {:decimal, "~> 3.0", override: true},
      {:membrane_mp4_plugin, "~> 0.36.10"},
      {:membrane_h26x_plugin, "~> 0.11.2"},
      # D-C2: the decoder element's stream format is `%Membrane.RawVideo{}`,
      # the ecosystem's one raw-frame vocabulary — never a custom struct.
      {:membrane_raw_video_format, "~> 0.4.1"},
      {:membrane_mpeg_ts_plugin, "~> 2.4.9"},
      {:membrane_tee_plugin, "~> 0.12.0"},
      {:membrane_rtp_plugin, "~> 0.31.5"},
      {:membrane_rtp_h264_plugin, "~> 0.20.6"},
      # D-M1 phase 4: RTSP-native ingest. The high-level client (gBillal) —
      # owns socket/depayload/keepalive and delivers whole H.264 access
      # units with pts as messages; digest auth fleet-proven in spike 0.2.
      # Fork ref: 0.8.2 crash-loops on an h264 track without an fmtp line
      # (in-band SPS/PPS — the Reolink substream), and on a key frame seen
      # before its in-band parameter sets. An upstream PR is owed once the
      # fix is reshaped (the first, gBillal/rtsp#33, was withdrawn for
      # cleanup); drop back to hex on the release that carries it.
      {:rtsp,
       github: "bbangert/rtsp", ref: "0a3a4b69664925a7fd14127c4a5b3e81c58e1907", override: true},
      # Transitive via rtsp, but `Membrane.RTSPDualStream.Source` parses the
      # SPS out of keyframes with it directly.
      {:media_codecs, "~> 0.10"},
      # D-C3: the motion gate's arithmetic — plain BinaryBackend, no EXLA;
      # the gate exists to *skip* heavy work, so it must not need an
      # accelerator (or a native dep) of its own.
      {:nx, "~> 0.13"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.14", only: [:dev, :test], runtime: false}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind cairn", "esbuild cairn"],
      "assets.deploy": [
        "tailwind cairn --minify",
        "esbuild cairn --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"],
      check: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "credo",
        "test"
      ]
    ]
  end
end
