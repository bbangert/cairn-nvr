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
      {Cairn.EventCheckpoint, []},
      {Task.Supervisor, name: Cairn.TaskSupervisor},
      {Cairn.DetectionAggregator, []},
      {Cairn.EventSupervisor, []},
      {Cairn.CameraSupervisor, []},
      {Cairn.Retention, []},
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
