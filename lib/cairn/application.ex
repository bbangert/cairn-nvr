defmodule Cairn.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Cairn.ExtractorTelemetry.attach()

    children = [
      CairnWeb.Telemetry,
      # Config first: everything else (Repo path, data dirs, cameras) hangs off it
      {Cairn.Config.Server, []},
      Cairn.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:cairn, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:cairn, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Cairn.PubSub},
      Cairn.Registry,
      {Cairn.CameraStatus, []},
      {Cairn.CameraControl, []},
      {CairnWeb.Api.StreamLimiter, []},
      {Cairn.EventCheckpoint, []},
      {Task.Supervisor, name: Cairn.TaskSupervisor},
      # After the Repo it writes through, before the camera trackers that cast
      # to it: a cast to a not-yet-started name is silently dropped, so
      # starting it later would lose every track of the boot's first moments.
      #
      # `manual: true` in the test env, where this singleton would otherwise
      # buffer finals cast by one test's camera tracker and flush them into
      # whichever sandbox connection is checked out when its timer fires — the
      # same escape as `.claude/solutions/boot-writes-escape-ecto-sandbox.md`,
      # from a process no test owns. Suites that exercise the recorder start
      # their own.
      {Cairn.TrackRecorder, manual: Application.get_env(:cairn, :track_recorder_manual, false)},
      # The whole tracking subtree — the pool of per-camera trackers and, under
      # the same `:rest_for_one`, the sweep that restores the trackers of
      # cameras whose checkpoint rows outlived them. The sweep re-runs whenever
      # the pool restarts (a tracker crash-looping past the pool's restart
      # intensity), which is the case where rows outlive their trackers: those
      # cameras get their `:host_restart` finals immediately rather than
      # waiting for each camera's next observation. Outside the media tree on
      # purpose — see the module's own doc.
      {Cairn.TrackerSupervisor, []},
      {Cairn.EventSupervisor, []},
      # Groups before cameras: a group listens on its members' UDP ports
      {Cairn.PluginGroupSupervisor, []},
      # Before the cameras that mint epochs into it
      {Cairn.StreamEpochs, []},
      {Cairn.CameraSupervisor, []},
      {Cairn.Retention, []},
      {CairnWeb.WebRTC.Supervisor, []},
      # Reconcile index with disk, then start cameras from config
      {Cairn.Boot, []},
      # Start to serve requests, typically the last entry
      CairnWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Cairn.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    CairnWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # Migrations run at boot everywhere (Boot's reconciliation needs the
    # schema); tests migrate via the mix test alias instead
    Application.get_env(:cairn, :skip_boot_migrations, false)
  end
end
