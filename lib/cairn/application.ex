defmodule Cairn.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Cairn.ExtractorTelemetry.attach()

    children = [
      # First on purpose: children stop in reverse start order, so this one's
      # terminate/2 — the bounded native-teardown drain — runs after every
      # camera and the host have died and queued their drops.
      Cairn.Native.Drain,
      CairnWeb.Telemetry,
      # The Repo needs no config process: with `db_in_data_dir`,
      # `Cairn.Repo.init/2` resolves `data_dir` from the env override or the
      # YAML file itself.
      Cairn.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:cairn, :ecto_repos), skip: skip_migrations?()},
      # One-shot, right after the migrator's first write creates cairn.db and
      # its WAL/SHM. `Task.start_link` returns at spawn, so this does not run
      # before `Cairn.Config.Server`'s own `DataDir.ensure!` call below — the
      # two are a belt-and-suspenders pair, not an ordering guarantee: this
      # one covers the files the migrator itself just created, and
      # `ensure!/1` (which also chmods) is the one that runs in order, after
      # the migrator, on the boot's next line. No-op when `db_in_data_dir` is
      # false (test env, which points the Repo at a DB outside the data dir)
      # so the child tree shape doesn't vary by env.
      %{
        id: :secure_db,
        start:
          {Task, :start_link,
           [
             fn ->
               if Application.get_env(:cairn, :db_in_data_dir, false) do
                 data_dir = Cairn.Config.resolve_data_dir(Cairn.Config.default_path())
                 Cairn.DataDir.secure_db(data_dir)
               end
             end
           ]},
        restart: :temporary
      },
      # After the migrated Repo, so a config source may read rows; before
      # everything that reads the config. Its `init/1` must not broadcast —
      # PubSub starts below it.
      {Cairn.Config.Server, []},
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
      {Cairn.PresenceSupervisor, []},
      {Cairn.EventSupervisor, []},
      # Before the cameras that mint epochs into it
      {Cairn.StreamEpochs, []},
      # After the epochs it announces under, before the cameras that open
      # streams on it. One engine for the whole VM, so it is not in a camera's
      # tree: a camera restart must not reload the model.
      {Cairn.Native.Host, []},
      # After the host, whose ETS tables it reads — and its own process, so that a
      # host inside a native call cannot stop the check that would report it.
      {Cairn.Native.Health, []},
      # Maps engine health onto the per-camera status surface. Its own
      # process for Health's reason: it reads the host under a deadline.
      {Cairn.Native.Status, []},
      # Observation-only evidence trail for the steady-state soak; off in test
      # (boot writes escape the sandbox), harmless and bounded elsewhere.
      {Cairn.SoakMonitor, []},
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
