defmodule Cairn.Config.Server do
  @moduledoc """
  Holds the active `Cairn.Config`. Loads it through its `source` at boot;
  `reload/0` loads again, diffs cameras against the running set and applies
  the diff (start/stop/restart camera trees, and refresh in place the
  cameras whose change reaches no subprocess). An invalid reload keeps the
  old config and returns the errors. Every applied config is announced on
  `Cairn.Config.topic/0` as `{:config_changed, diff}` — see `subscribe/0`. A
  restart that finds a surviving snapshot re-applies and re-announces once at
  boot, against the fresh load, since a crash between an apply's commit and
  its broadcast would otherwise leave that config never applied to the
  runtime and never announced at all.

  The source is the `source:` opt, else the `:config_loader` app env — a
  1-arity fun of the config path, or `{module, function}` naming one; the
  file source is `Cairn.Config.load_file/1`. A missing or malformed loader
  is the one failure this module does not degrade around: `init/1` raises
  and the node does not boot, because a config process with no source has
  nothing to install.

  A load that fails at boot installs the source's fallback when it offers
  one — the file's globals with no cameras — so the readers that run
  regardless (`Cairn.Retention`, `Cairn.Boot`'s reconciler, the HA token
  behind `/api`) work on the operator's `data_dir`, retention and token, not
  the struct defaults. One visible consequence: on a failed boot `/api`
  honours the operator's token and answers with an empty camera list, where
  it used to refuse every request with 401.

  Detection lives in `Cairn.Native.Host`, so the new config goes there
  first (`reconfigure/1`) — the model a camera's next session opens a
  stream on should already be the new one when its tree restarts.

  `update/3` runs the caller's write, the source read and `Cairn.Config.from_map/1`
  inside one immediate-mode transaction on this process, so the store never
  holds a fleet the validator rejects and two sessions' saves serialize on the
  mailbox instead of racing the cross-camera rules — and, with
  `reject_skipped:`, a save cannot leave its own camera skipped and dark. The
  cost is that a save holds the server for all of that plus the apply, and
  `apply_diff` can take seconds on restart-class changes — so `get/1` and
  `last_load/1` callers, on their 5 s budget, can see a slow answer while a
  save is in flight.

  A named server publishes each config it installs as a `:persistent_term`
  snapshot *before* applying it (`snapshot/1`, `snapshot_camera/2`,
  `known_ids/1`). A camera tree restarted by its own supervisor is rebuilt
  from the child spec its tree was born with, and the snapshot is how the
  owner recovers what a refresh since then delivered; the runtime owners read
  it to refuse a write for a camera that no longer exists (they prune against
  the membership the diff carries, not this one — `t:diff/0`). A term rather
  than a call because `apply_diff` runs inside this
  process — a camera started from a reload that called back here would wait
  on the very call that is starting it, and the owners read it in the same
  window. For the duration of an apply the snapshot therefore leads `get/1`,
  which answers the previous config until the apply returns.

  Every config this server installs carries a `version` (each applied reload
  or save +1; a rejected or failed write leaves it alone), on the snapshot,
  on `get/1` and in the broadcast as `diff.version`. The count is monotonic
  for as long as the `:persistent_term` snapshot lives, which is longer than
  this process: `init/1` seeds it from the surviving snapshot, so a restarted
  server continues at the version its predecessor last installed rather than
  handing out a 1 that a still-pinned save would match. A fresh node, with no
  term, starts at 1.
  `update/3`'s `expected_version:` is checked against it before the
  transaction opens, so a save made from a stale view is refused with
  `{:error, {:write, {:stale, current}}}` rather than applied over a fleet
  its caller never saw. The comparison is exact and not advisory because
  writes serialize on this mailbox: no version can be installed between the
  check and the transaction it guards. It replaces the two guesses the UI
  made instead — "the fleet changed underneath this save", and treating any
  `{:config_changed, _}` as confirmation of a save that had timed out.
  """

  use GenServer

  require Logger

  alias Cairn.Config
  alias Cairn.Native.Host

  @typedoc "Which cameras the new config adds, removes, restarts and refreshes."
  @type camera_diff :: %{
          added: [String.t()],
          removed: [String.t()],
          changed: [String.t()],
          refreshed: [String.t()]
        }

  @typedoc """
  A `t:camera_diff/0` plus the `version` of the config that produced it, so a
  subscriber that lost an answer to a timeout can tell from the next
  broadcast whether its own write is the one that landed, the `server` that
  published it — its registered name, or its pid when unnamed — and `known`,
  the camera ids that config names (`known_ids/1`'s answer, frozen at this
  version).

  `known` rides the diff because the snapshot moves and the mailbox does not:
  a delete followed at once by a create of the same id would leave an owner
  handling the delete against a snapshot that already names the id again, and
  the re-created camera would inherit the deleted one's row. Pruning against
  the membership of the version that produced the diff gives each broadcast
  the fleet it was about.

  `Cairn.Config.topic/0` is one topic for every server, so a private server
  (a test's) broadcasts onto the same wire as the application singleton. The
  runtime owners — `Cairn.CameraStatus`, `Cairn.CameraControl`,
  `Cairn.EventCheckpoint`, `Cairn.PresenceCheckpoint`, and the
  `Cairn.CameraReaper` that ends a deleted camera's recorder, tracker and
  extractors — own tables and processes for the singleton's fleet, so acting on another
  server's diff would prune them against a fleet that diff never described.
  They match `server: Cairn.Config.Server` and ignore the rest.
  """
  @type diff :: %{
          added: [String.t()],
          removed: [String.t()],
          changed: [String.t()],
          refreshed: [String.t()],
          version: non_neg_integer(),
          server: atom() | pid(),
          known: MapSet.t(String.t())
        }

  @typedoc "Cameras a source left out of the config, and why."
  @type skipped :: %{String.t() => [String.t()]}

  @typedoc """
  What a source answers. On error, the fallback is the best config the
  source can stand behind without its cameras, or `nil`.
  """
  @type source_result ::
          {:ok, Config.t(), [String.t()], skipped()}
          | {:error, [String.t()], Config.t() | nil}

  @type source :: (Path.t() -> source_result())

  @typedoc "The `source:` opt / `:config_loader` app env: a source, or `{module, function}` naming one."
  @type loader :: source() | {module(), atom()}

  @type last_load :: %{warnings: [String.t()], errors: [String.t()], skipped: skipped()}

  @typedoc """
  `update/3`'s write, run inside the transaction. A 1-arity fun is handed the
  server's config path: a write that has to validate a row the fleet re-render
  will not see — a disabled one, which `Cairn.Cameras.raw_maps/0` does not
  render — needs the same file globals the server loads through, and only the
  server knows which file that is.
  """
  @type write_fun :: (-> :ok | {:error, term()}) | (Path.t() -> :ok | {:error, term()})

  # Atom names only: the snapshot is keyed by the name, and every reader of
  # a snapshot has to be able to spell it.
  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil ->
        GenServer.start_link(__MODULE__, opts)

      name when is_atom(name) ->
        GenServer.start_link(__MODULE__, opts, name: name)

      other ->
        raise ArgumentError, "#{inspect(__MODULE__)} name must be an atom, got: #{inspect(other)}"
    end
  end

  @doc """
  The camera and config a restarting tree should build from, from the
  snapshot the server named `server` last published — `:error` when it has
  published none or the camera has since left the config.
  """
  @spec snapshot_camera(String.t(), atom()) :: {:ok, Config.Camera.t(), Config.t()} | :error
  def snapshot_camera(camera_id, server \\ __MODULE__) when is_atom(server) do
    with %Config{} = config <- :persistent_term.get(snapshot_key(server), nil),
         %Config.Camera{} = cam <- Enum.find(config.cameras, &(&1.id == camera_id)) do
      {:ok, cam, config}
    else
      _absent -> :error
    end
  end

  @doc false
  @spec snapshot_key(atom()) :: {module(), :snapshot, atom()}
  def snapshot_key(server) when is_atom(server), do: {__MODULE__, :snapshot, server}

  @doc """
  The config the server named `server` last published, or `nil` before its
  first publish (and always, for an unnamed server). A term read rather than
  a call: the runtime owners read it while this server is inside an apply,
  which is the one moment it cannot answer.
  """
  @spec snapshot(atom()) :: Config.t() | nil
  def snapshot(server \\ __MODULE__) when is_atom(server) do
    case :persistent_term.get(snapshot_key(server), nil) do
      %Config{} = config -> config
      nil -> nil
    end
  end

  @doc """
  The camera ids the published snapshot names, or `nil` when there is none.

  The *moving* view: it answers for whatever config is installed when it is
  called, which is what a write has to be judged against (a write for a
  re-created id must be accepted). An owner pruning on a broadcast wants the
  membership of the version that produced it instead — `diff.known`.

  `dormant` counts: a disabled or skipped camera is a row that still exists,
  and an owner that pruned it would drop the control overlay and status of a
  camera the operator is about to switch back on.
  """
  @spec known_ids(atom()) :: MapSet.t(String.t()) | nil
  def known_ids(server \\ __MODULE__) when is_atom(server) do
    case snapshot(server) do
      %Config{} = config -> ids(config)
      nil -> nil
    end
  end

  defp ids(%Config{} = config), do: MapSet.new(config.cameras ++ config.dormant, & &1.id)

  @spec get(GenServer.server()) :: Config.t()
  def get(server \\ __MODULE__), do: GenServer.call(server, :get)

  @spec camera(String.t()) :: {:ok, Config.Camera.t()} | :error
  def camera(camera_id, server \\ __MODULE__) do
    case Enum.find(get(server).cameras, &(&1.id == camera_id)) do
      nil -> :error
      cam -> {:ok, cam}
    end
  end

  @spec data_dir(GenServer.server()) :: String.t()
  def data_dir(server \\ __MODULE__), do: get(server).data_dir

  @doc "Configured HA integration token, or `nil` when the integration is disabled."
  @spec ha_token(GenServer.server()) :: String.t() | nil
  def ha_token(server \\ __MODULE__), do: get(server).ha_token

  @doc """
  Warnings, errors and skipped cameras from the last load, reload or accepted
  save (for the UI). A failed reload carries only its errors: the warnings and
  skips of the config still running describe a file that is gone. A rejected
  `update/3` leaves this alone — its errors are the caller's form, not the
  health of the config that is still running.
  """
  @spec last_load(GenServer.server()) :: last_load()
  def last_load(server \\ __MODULE__), do: GenServer.call(server, :last_load)

  @spec reload(GenServer.server()) ::
          {:ok, diff(), [String.t()]} | {:error, [String.t()]}
  def reload(server \\ __MODULE__), do: GenServer.call(server, :reload, 30_000)

  @doc """
  Runs `write_fun` against the store, re-reads and re-validates the whole
  fleet through the source in the same transaction, and applies the result
  exactly as `reload/1` does. A fleet the validator rejects rolls the write
  back, so the errors reach the caller and the row never lands.

  `reject_skipped: id | [id]` extends that to the cameras the save is *about*:
  a source free to skip a faulty row rolls the write back instead when one of
  these is the row it skipped, and the caller gets that camera's errors.

  `expected_version: n` pins the save to the fleet its caller read: the
  handler compares `n` with the installed config's version before the
  transaction opens and answers `{:error, {:write, {:stale, current}}}`
  when they differ. Absent, nothing is checked.

  `write_fun` may take the config path (`t:write_fun/0`).

  `{:error, errors}` is the validator's; `{:error, {:write, reason}}` is
  `write_fun`'s own (a changeset, a DB fault, a wrong-shaped return, or an
  exception the closure raised).
  """
  @spec update(GenServer.server(), write_fun(), keyword()) ::
          {:ok, diff(), [String.t()]} | {:error, [String.t()]} | {:error, {:write, term()}}
  def update(server \\ __MODULE__, write_fun, opts \\ [])
      when (is_function(write_fun, 0) or is_function(write_fun, 1)) and is_list(opts) do
    reject = Keyword.get(opts, :reject_skipped, [])
    expected = Keyword.get(opts, :expected_version)
    GenServer.call(server, {:update, write_fun, reject, expected}, 30_000)
  end

  @doc """
  Subscribes the caller to `Cairn.Config.topic/0`: `{:config_changed, diff}`
  — the added, removed, changed and refreshed ids, the new config's `version`,
  the ids it `known`s and the `server` that published it — after every config
  applied past boot. Every server shares the topic, so a subscriber whose
  reaction reads one server's state must filter on `diff.server`
  (`t:diff/0`). Node-local: a subscriber on another node hears nothing.
  """
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Cairn.PubSub, Config.topic())

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path) || Config.default_path()
    apply_diff = Keyword.get(opts, :apply_diff, &Cairn.CameraSupervisor.apply_diff/2)
    apply_native = Keyword.get(opts, :apply_native, &Host.reconfigure/1)

    source =
      opts
      |> Keyword.get_lazy(:source, fn -> Application.fetch_env!(:cairn, :config_loader) end)
      |> source_fun()

    name = Keyword.get(opts, :name, __MODULE__)
    # Fetched once and held rather than re-read after publish/2 overwrites the
    # term: it is both the version seed and, when present, the "old" side of
    # the restart-announce diff below.
    surviving = name && snapshot(name)

    state = %{
      path: path,
      source: source,
      # An unnamed server has no key to publish under; nothing reads a
      # snapshot of a server it cannot name.
      snapshot: name,
      apply_diff: apply_diff,
      apply_native: apply_native,
      config: %Config{version: surviving_version(surviving)},
      warnings: [],
      errors: [],
      skipped: %{}
    }

    case load(state) do
      {:ok, config, warnings, skipped} ->
        Enum.each(warnings, &Logger.warning("config: #{&1}"))
        config = installed(state, config)
        Cairn.DataDir.ensure!(config.data_dir)
        publish(state, config)
        announce_restart(state, surviving, config)
        {:ok, %{state | config: config, warnings: warnings, skipped: skipped}}

      {:error, errors, fallback} ->
        Enum.each(errors, &Logger.error("config: #{&1}"))

        config =
          case fallback do
            %Config{} ->
              Logger.error("config: starting with the loaded settings and no cameras")
              fallback

            nil ->
              Logger.error("config: starting with empty defaults (no cameras)")
              %Config{}
          end

        config = installed(state, config)
        Cairn.DataDir.ensure!(config.data_dir)
        publish(state, config)
        announce_restart(state, surviving, config)
        {:ok, %{state | config: config, errors: errors}}
    end
  end

  # The owners' only prune path is the broadcast at the end of
  # `apply_config/4`; a callback that raises after that apply's transaction
  # committed and its snapshot published crashes this process before the
  # broadcast fires. The restart above re-seeds from the surviving snapshot
  # and re-publishes, but without this, never re-applies or re-broadcasts —
  # the owners would keep pruning against the membership before the apply that
  # crashed until some later, unrelated apply finally caught them up. Diffing
  # the surviving snapshot against the fresh load, applying it and
  # broadcasting once at boot closes that gap. A fresh boot has no surviving snapshot to diff against
  # and stays silent, as it always has.
  #
  # What this does not cover: a PubSub restart that drops subscriptions
  # while the owners themselves keep running. Cairn is single-node
  # `:one_for_one`, so that gap is accepted rather than solved here.
  #
  # Skipped when PubSub is not up: a whole-tree restart in the same VM keeps
  # the persistent term, and this server starts before `Cairn.PubSub`. A
  # broadcast then would fail the boot, and neither it nor the replay below is
  # needed — that restart gives every owner a fresh, empty table and starts
  # every camera tree from the config this boot installs.
  defp announce_restart(_state, nil, _new_config), do: :ok

  defp announce_restart(state, %Config{} = surviving, new_config) do
    if Process.whereis(Cairn.PubSub) do
      diff = build_diff(surviving, new_config, state.snapshot || self())

      # The crash that lost the broadcast is a crash *inside* one of these two,
      # so the runtime is the half of the world this restart cannot assume:
      # the store, the snapshot and the owners already name the new fleet while
      # the camera trees and the engine may be the old one, or half of it.
      # Replayed in `apply_config/4`'s order and ahead of the broadcast, so a
      # commit that never reached its apply cannot leave the runtime behind the
      # fleet for as long as the node runs. Both are safe over a partly applied
      # attempt: `Cairn.CameraSupervisor` stops by registry lookup and starts
      # only what is not running, and `Cairn.Native.Host.reconfigure/1` takes a
      # whole config.
      state.apply_native.(new_config)
      state.apply_diff.(diff, new_config)

      Phoenix.PubSub.local_broadcast(Cairn.PubSub, Config.topic(), {:config_changed, diff})
    else
      :ok
    end
  end

  @impl true
  def handle_call(:get, _from, state), do: {:reply, state.config, state}

  def handle_call(:last_load, _from, state) do
    {:reply, %{warnings: state.warnings, errors: state.errors, skipped: state.skipped}, state}
  end

  def handle_call(:reload, _from, state) do
    case load(state) do
      {:ok, new_config, warnings, skipped} ->
        {diff, state} = apply_config(state, new_config, warnings, skipped)
        {:reply, {:ok, diff, warnings}, state}

      {:error, errors, _fallback} ->
        {:reply, {:error, errors}, %{state | errors: errors, warnings: [], skipped: %{}}}
    end
  end

  def handle_call({:update, write_fun, reject, expected}, _from, state) do
    cond do
      file_source?(state.source) ->
        # A row written under the file source would never be read back — the
        # render comes from the file — so a caller (or a test) that forgot to
        # point the server at a store is told, not silently obeyed.
        {:reply, {:error, ["update needs a DB-backed config source"]}, state}

      # Before the transaction, not inside it: a stale save must not take the
      # write lock, and there is nothing to roll back if it never opened.
      not is_nil(expected) and expected != state.config.version ->
        {:reply, {:error, {:write, {:stale, state.config.version}}}, state}

      true ->
        do_update(state, write_fun, reject)
    end
  end

  defp file_source?(source), do: source == Function.capture(Config, :load_file, 1)

  defp do_update(state, write_fun, reject) do
    case transact(state, write_fun, reject) do
      {:ok, {new_config, warnings, skipped}} ->
        {diff, state} = apply_config(state, new_config, warnings, skipped)
        {:reply, {:ok, diff, warnings}, state}

      {:error, {:invalid, errors}} ->
        # Form errors, not config health: the running config is untouched and
        # still valid, so `last_load` must not start claiming otherwise.
        {:reply, {:error, errors}, state}

      {:error, {:write, reason}} ->
        {:reply, {:error, {:write, reason}}, state}
    end
  end

  # `mode: :immediate` takes the write lock at BEGIN rather than at the first
  # write, so the render between the two cannot be raced by another writer.
  defp transact(state, write_fun, reject) do
    Cairn.Repo.transaction(fn -> attempt(state, write_fun, reject) end, mode: :immediate)
  rescue
    # A DB fault is the caller's write error, not a reason to take the config
    # process down and with it every camera the old config is still running.
    e in [Exqlite.Error, DBConnection.ConnectionError] -> {:error, {:write, e}}
    # `write_fun` is the caller's code running in this process; its bug is the
    # caller's error, not a reason the config server and every camera it holds
    # should die for a save that never applied.
    e -> {:error, {:write, e}}
  end

  defp attempt(state, write_fun, reject) do
    with :ok <- run_write(write_fun, state.path),
         {:ok, config, warnings, skipped} <- load(state),
         [] <- own_skips(reject, skipped) do
      {config, warnings, skipped}
    else
      {:error, errors, _fallback} -> Cairn.Repo.rollback({:invalid, errors})
      {:error, reason} -> Cairn.Repo.rollback({:write, reason})
      own_errors when is_list(own_errors) -> Cairn.Repo.rollback({:invalid, own_errors})
      # A closure that forgot to normalize its result must not take the
      # config server, and with it every camera, down.
      other -> Cairn.Repo.rollback({:write, {:bad_return, other}})
    end
  end

  defp run_write(write_fun, _path) when is_function(write_fun, 0), do: write_fun.()
  defp run_write(write_fun, path), do: write_fun.(path)

  # A per-camera fault skips the row on a *load*, so one drifted camera cannot
  # take the fleet down with it. On a save that row is the operator's own act:
  # its faults are form errors, and the store must not accept a row that would
  # only go dark. Another camera's skip is not this save's doing and does not
  # reject it.
  defp own_skips(reject, skipped),
    do: Enum.flat_map(List.wrap(reject), &Map.get(skipped, &1, []))

  # Shared by `apply_config/4` and the restart announce in `init/1`, so the
  # two `{:config_changed, diff}` producers cannot drift into different
  # shapes for `t:diff/0`.
  defp build_diff(old_config, new_config, server) do
    old_config
    |> diff_cameras(new_config)
    |> Map.merge(%{
      version: new_config.version,
      server: server,
      known: ids(new_config)
    })
  end

  # The ok arm shared by `:reload` and `{:update, _}`, so the orderings below
  # cannot drift between the two paths. The one every reader depends on:
  # publish the snapshot, then apply, then broadcast — the snapshot is what a
  # write is judged against, so it must already name the new fleet, and a
  # write handled before the publish is caught by the prune the broadcast
  # that follows triggers. The prune itself runs against `diff.known`, the
  # membership frozen here: the snapshot has moved on by the time a slow
  # owner reaches this diff, and a delete pruned against a later create's
  # fleet prunes nothing (`t:diff/0`).
  defp apply_config(state, new_config, warnings, skipped) do
    new_config = installed(state, new_config)
    diff = build_diff(state.config, new_config, state.snapshot || self())

    # Before the diff: newly spawned ports redirect logs into the (possibly
    # changed) data_dir, so its log subdir must already exist
    Cairn.DataDir.ensure!(new_config.data_dir)
    # A tree the diff restarts may be rebuilt by its supervisor at any point
    # after the apply starts, and must find this fleet, not the last one.
    publish(state, new_config)
    # Before the cameras: detection is the in-VM engine, so the model a
    # restarted camera will open a stream on should already be the new
    # one. The call is asynchronous, so this is an ordering of sends
    # rather than of loads.
    state.apply_native.(new_config)
    state.apply_diff.(diff, new_config)
    state = %{state | config: new_config, warnings: warnings, errors: [], skipped: skipped}
    # Cairn is a single node by design (the DNSCluster child is generator
    # boilerplate and never configured); there is no peer for this to reach.
    # local_broadcast states that: a config is this node's own and every
    # subscriber acts on node-local state.
    Phoenix.PubSub.local_broadcast(Cairn.PubSub, Config.topic(), {:config_changed, diff})
    {diff, state}
  end

  # A source is the seam a later store plugs into, so its answer is checked
  # at the boundary: a wrong shape names the source here instead of failing
  # as a bare clause error inside the arm that would have installed it.
  defp load(state) do
    case state.source.(state.path) do
      {:ok, %Config{}, warnings, skipped} = ok when is_list(warnings) and is_map(skipped) ->
        ok

      {:error, errors, fallback} = error
      when is_list(errors) and (is_nil(fallback) or is_struct(fallback, Config)) ->
        error

      other ->
        raise ArgumentError,
              "config source #{inspect(state.source)} answered #{inspect(other)}; expected " <>
                "{:ok, %Cairn.Config{}, warnings, skipped} or {:error, errors, fallback | nil}"
    end
  end

  # The version is stamped here rather than by whatever built the config, so
  # only a config this server is about to install can carry one: a candidate
  # a form validated, or a load that was rejected, keeps `from_map/1`'s 0.
  defp installed(state, config), do: %{config | version: state.config.version + 1}

  # Overwriting a persistent term scans every process for references to the
  # old one — bounded here by boot plus the reload and save rate, both
  # operator paced. An ETS table owned by this server is the alternative if a
  # save rate ever makes that scan measurable.
  defp publish(%{snapshot: nil}, _config), do: :ok
  defp publish(%{snapshot: name}, config), do: :persistent_term.put(snapshot_key(name), config)

  # The snapshot outlives the process that published it, so a restart resumes
  # its predecessor's count: restarting at 1 would re-issue versions that
  # pinned saves still hold, and a stale `expected_version:` would pass.
  defp surviving_version(nil), do: 0
  defp surviving_version(%Config{version: version}), do: version

  defp source_fun(fun) when is_function(fun, 1), do: fun
  # A named capture, so the boundary error prints `&Mod.fun/1`, not a closure.
  defp source_fun({mod, fun}) when is_atom(mod) and is_atom(fun),
    do: Function.capture(mod, fun, 1)

  defp source_fun(other) do
    raise ArgumentError,
          "the config loader (`source:` opt or the :cairn, :config_loader app env) must be a " <>
            "1-arity fun or {module, function}, got: #{inspect(other)}"
  end

  # Whether installing `new` over `old` would restart `camera_id`'s tree — the
  # camera diff's own test, public so a form can ask it of a candidate config
  # it has built but not written. Both configs must be resolved: the answer
  # reads globals and profiles, not the camera's raw settings. False when
  # either config is missing the camera: an add or a remove is not a restart,
  # and neither is a prediction made against a config that could not be read.
  @doc false
  @spec would_restart?(Config.t(), Config.t(), String.t()) :: boolean()
  def would_restart?(old, new, camera_id) do
    with %Config.Camera{} = old_cam <- Enum.find(old.cameras, &(&1.id == camera_id)),
         %Config.Camera{} = new_cam <- Enum.find(new.cameras, &(&1.id == camera_id)) do
      camera_changed?(old, new, old_cam, new_cam)
    else
      _absent -> false
    end
  end

  @doc false
  @spec diff_cameras(Config.t(), Config.t()) :: camera_diff()
  def diff_cameras(old, new) do
    old_by_id = Map.new(old.cameras, &{&1.id, &1})
    new_by_id = Map.new(new.cameras, &{&1.id, &1})
    old_ids = MapSet.new(Map.keys(old_by_id))
    new_ids = MapSet.new(Map.keys(new_by_id))

    # `changed` restarts the camera's tree, `refreshed` hands the running one
    # the new config: a camera is in exactly one of them, and in neither when
    # nothing about it moved.
    {changed, refreshed} =
      Enum.reduce(MapSet.intersection(old_ids, new_ids), {[], []}, fn id, {changed, refreshed} ->
        cond do
          camera_changed?(old, new, old_by_id[id], new_by_id[id]) -> {[id | changed], refreshed}
          camera_refreshed?(old, new, old_by_id[id], new_by_id[id]) -> {changed, [id | refreshed]}
          true -> {changed, refreshed}
        end
      end)

    diff(old_ids, new_ids, changed, refreshed)
  end

  # The camera inputs that reach a subprocess or are baked into a child spec
  # at tree init, and so cannot be swapped into a running camera:
  # `rtsp_url`, `transcode` and `extra_ffmpeg_args` are ffmpeg's argv;
  # `plugin` selects the profile the detect branch is built on and
  # `min_score` the stream params it opens with — both resolved at session
  # start, not refreshable into an open stream.
  #
  # The contract for a field added to `Cairn.Config.Camera` later: the
  # default is refresh-only. Nothing lands in this list by being new — it
  # goes here only on the deliberate finding that it reaches a subprocess.
  # `ingest` is here because it selects the session's source process itself
  # (the ffmpeg OS process vs the RTSP client) and the pipeline's ingest
  # chain — nothing a running session can swap in place. `substream_url` is
  # the same reach one level up: whether there is a second ingest at all, and
  # therefore which tee the detect branch is built off, is decided when the
  # pipeline is constructed.
  @restart_fields [
    :rtsp_url,
    :substream_url,
    :plugin,
    :ingest,
    :min_score,
    :transcode,
    :extra_ffmpeg_args,
    # The gate element is built into the detect branch at birth
    # (`Cairn.Pipeline.Camera.motion_gate/2`) — a changed scene config is a
    # different branch, not a refreshable knob.
    :motion_json
  ]

  @doc """
  The camera fields baked into a subprocess or a child spec at tree birth,
  so a running camera cannot take them in place. Not the whole restart set:
  the resolved comparisons in the camera diff (pre-window, tracker core,
  sample rate, live-track cap, tier, rung) restart a camera too.
  """
  @spec restart_fields() :: [atom()]
  def restart_fields, do: @restart_fields

  # `pre_window_seconds` is compared *resolved* rather than read off the
  # camera struct (camera override or global): `Cairn.Camera.init/1` bakes
  # it into the RingBuffer child spec, so a pre-window refreshed in place
  # would leave the ring at its old capacity while everything else believed
  # the new one.
  #
  # The tracker core, the sample rate and the live-track cap are compared
  # resolved for the same reason and with the same reach: each is baked into a
  # child of the detect branch at build time, which a running pipeline cannot
  # re-wire, and each can be named above the camera — the core at any of three
  # levels, the rate on the profile alone, the cap camera → profile → global —
  # so comparing the camera's own field would miss the rest.
  #
  # `sample_fps` is the branch's delivery rate (SampleGate) and sizes a
  # frame-counting core's lost-track buffer — the motion gate's calibration
  # window no longer reads it; `max_live_tracks` is the element's `max_suspended`
  # and `Membrane.MOTTracker.SparseTrack`'s `max_live`. It stays in the policy
  # as well — `Cairn.Tracker` reads its live cap off every batch's context — so
  # a camera on that core gets the new cap either way; this is for the two that
  # only ever read it at birth.
  #
  # The rest of the effective policy — `post`/`max`, the other tracking bounds,
  # the `track:` / `record:` tiers — is host-side and refreshes in place through
  # `Cairn.PipelineOwner.refresh/3`.
  # The capability tier joins them for the same reason at a larger grain:
  # it picks the whole TAIL of the detect branch (`Cairn.Pipeline.Camera`'s
  # `detect_tail/4` — presence sink vs stamper/tracker/track sink), and a
  # refresh routed by the old tail would feed the new policy to a shape the
  # tier no longer means.
  #
  # The resolved ladder rung is the newest resolved comparison (D-L5): a
  # fleet edit elsewhere on the node can move N across a rung boundary,
  # which is a model change for this camera with none of its own fields
  # moving — engine first, then the restart, the tested reload ordering.
  # The rung's derived sample_fps rides the `sample_fps/2` row above; the
  # rung compares as well because two rungs can derive the same clamped
  # rate while the model differs.
  defp camera_changed?(old, new, old_cam, new_cam) do
    Map.take(old_cam, @restart_fields) != Map.take(new_cam, @restart_fields) or
      Config.windows(old, old_cam).pre != Config.windows(new, new_cam).pre or
      Config.tracker(old, old_cam) != Config.tracker(new, new_cam) or
      Config.sample_fps(old, old_cam) != Config.sample_fps(new, new_cam) or
      Config.policy(old, old_cam).max_live_tracks != Config.policy(new, new_cam).max_live_tracks or
      Map.get(Config.policy(old, old_cam), :tier) != Map.get(Config.policy(new, new_cam), :tier) or
      Config.resolved_rung(old, old_cam) != Config.resolved_rung(new, new_cam)
  end

  # Everything else the running camera was handed: the camera struct itself
  # (the tiers, retention, the refresh-only windows) and its effective
  # policy, which a *global* window or tracking edit moves without touching
  # the struct.
  defp camera_refreshed?(old, new, old_cam, new_cam) do
    old_cam != new_cam or Config.policy(old, old_cam) != Config.policy(new, new_cam)
  end

  defp diff(old_keys, new_keys, changed, refreshed) do
    %{
      added: MapSet.difference(new_keys, old_keys) |> Enum.sort(),
      removed: MapSet.difference(old_keys, new_keys) |> Enum.sort(),
      changed: Enum.sort(changed),
      refreshed: Enum.sort(refreshed)
    }
  end
end
