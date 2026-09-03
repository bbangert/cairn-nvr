defmodule Cairn.Config.Server do
  @moduledoc """
  Holds the active `Cairn.Config`. Loads it through its `source` at boot;
  `reload/0` loads again, diffs cameras against the running set and applies
  the diff (start/stop/restart camera trees, and refresh in place the
  cameras whose change reaches no subprocess). An invalid reload keeps the
  old config and returns the errors. Every applied config is announced on
  `Cairn.Config.topic/0` as `{:config_changed, diff}` — see `subscribe/0`.

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

  A write whose commit obliges cleanup elsewhere (pruning a deleted camera's
  runtime state) hands it over as `after_apply:` rather than running it on
  return: the commit and the apply happen here whatever becomes of the
  caller, so a caller that dies or gives up on its 30 s call would otherwise
  leave the cleanup undone — and a prune racing a re-create of the same id
  from another session can delete a checkpoint that belongs to the new
  camera. It runs before the config is announced on `Cairn.Config.topic/0`:
  a prune can block up to another owner's call timeout, and a subscriber
  that reacted to the broadcast by calling `get/1` would otherwise queue
  behind it on this same process.

  Cleanup that must win a race against the *commit itself* — a deleted
  camera's control tombstone — belongs in `write_fun` rather than in any
  callback: a caller that checked the config and found the camera present,
  then called `CameraControl.set/2`, can land its write between the commit
  and anything that runs after it. The cost is that such a step is outside
  the transaction and so is not undone by a rollback, which is what
  `after_rollback:` is for.

  The order for a write carrying all three: write closure → commit or
  rollback → `after_commit:` (committed) or `after_rollback:` (not) →
  publish/apply → `after_apply:` → broadcast. The last two are the committed
  path only.

  A named server publishes each config it installs as a `:persistent_term`
  snapshot *before* applying it, for `snapshot_camera/2`: a camera tree
  restarted by its own supervisor is rebuilt from the child spec its tree
  was born with, and the snapshot is how the owner recovers what a refresh
  since then delivered. A term rather than a call because `apply_diff`
  runs inside this process — a camera started from a reload that called
  back here would wait on the very call that is starting it. For the
  duration of an apply the snapshot therefore leads `get/1`, which answers
  the previous config until the apply returns.
  """

  use GenServer

  require Logger

  alias Cairn.Config
  alias Cairn.Native.Host

  @type diff :: %{
          added: [String.t()],
          removed: [String.t()],
          changed: [String.t()],
          refreshed: [String.t()]
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

  Three callbacks, all run on this process so a caller that dies or gives up
  on its call still gets them, in this order: `after_commit:` (0-arity) right
  after the transaction commits, before the new config is published or
  applied; `after_apply:` (1-arity, the applied diff) once the apply has been
  attempted — it runs even when the apply raised, so a committed delete's
  cleanup is never lost, and is not proof the runtime took the config — and
  before it is announced; and `after_rollback:` (0-arity) instead of both
  whenever the transaction did *not* commit — a validator rejection or a
  write failure.

  `after_rollback:` is what undoes the part of a write that the database
  cannot: a step the closure took outside the transaction (installing a
  control tombstone ahead of the row delete it guards) survives the rollback
  and has to be reversed by hand.

  `write_fun` is 0-arity, or 1-arity to be handed the server's config `path`:
  a write that must validate against the file's globals needs the path the
  server loads from, which only the server knows.

  `{:error, errors}` is the validator's; `{:error, {:write, reason}}` is
  `write_fun`'s own (a changeset, a DB fault, a wrong-shaped return, an
  exception the closure raised, or `{:exit, reason}` / `{:throw, value}` when
  it exited or threw — a closure calling a restarting sibling exits).
  """
  @spec update(
          GenServer.server(),
          (-> :ok | {:error, term()}) | (Path.t() -> :ok | {:error, term()}),
          keyword()
        ) ::
          {:ok, diff(), [String.t()]} | {:error, [String.t()]} | {:error, {:write, term()}}
  def update(server \\ __MODULE__, write_fun, opts \\ [])
      when (is_function(write_fun, 0) or is_function(write_fun, 1)) and is_list(opts) do
    reject = Keyword.get(opts, :reject_skipped, [])

    callbacks = %{
      commit: zero_arity_fun(:after_commit, Keyword.get(opts, :after_commit)),
      rollback: zero_arity_fun(:after_rollback, Keyword.get(opts, :after_rollback)),
      apply: after_apply_fun(Keyword.get(opts, :after_apply))
    }

    GenServer.call(server, {:update, write_fun, reject, callbacks}, 30_000)
  end

  defp zero_arity_fun(_opt, nil), do: nil
  defp zero_arity_fun(_opt, fun) when is_function(fun, 0), do: fun

  defp zero_arity_fun(opt, other) do
    raise ArgumentError, "#{opt}: must be a 0-arity fun, got: #{inspect(other)}"
  end

  defp after_apply_fun(nil), do: nil
  defp after_apply_fun(fun) when is_function(fun, 1), do: fun

  defp after_apply_fun(other) do
    raise ArgumentError, "after_apply: must be a 1-arity fun, got: #{inspect(other)}"
  end

  @doc """
  Subscribes the caller to `Cairn.Config.topic/0`: `{:config_changed, diff}`
  — the added, removed, changed and refreshed ids — after every config
  applied past boot.
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

    state = %{
      path: path,
      source: source,
      # An unnamed server has no key to publish under; nothing reads a
      # snapshot of a server it cannot name.
      snapshot: Keyword.get(opts, :name, __MODULE__),
      apply_diff: apply_diff,
      apply_native: apply_native,
      config: %Config{},
      warnings: [],
      errors: [],
      skipped: %{}
    }

    case load(state) do
      {:ok, config, warnings, skipped} ->
        Enum.each(warnings, &Logger.warning("config: #{&1}"))
        Cairn.DataDir.ensure!(config.data_dir)
        publish(state, config)
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

        Cairn.DataDir.ensure!(config.data_dir)
        publish(state, config)
        {:ok, %{state | config: config, errors: errors}}
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

  def handle_call({:update, write_fun, reject, callbacks}, _from, state) do
    if file_source?(state.source) do
      # A row written under the file source would never be read back — the
      # render comes from the file — so a caller (or a test) that forgot to
      # point the server at a store is told, not silently obeyed.
      {:reply, {:error, ["update needs a DB-backed config source"]}, state}
    else
      do_update(state, write_fun, reject, callbacks)
    end
  end

  defp file_source?(source), do: source == Function.capture(Config, :load_file, 1)

  defp do_update(state, write_fun, reject, callbacks) do
    case transact(state, write_fun, reject) do
      {:ok, {new_config, warnings, skipped}} ->
        # Before the diff/publish/apply: see the moduledoc on `after_commit:`
        # — this has to beat `apply_diff` to close the check-then-write window.
        run_zero_arity(:after_commit, callbacks.commit)
        {diff, state} = apply_config(state, new_config, warnings, skipped, callbacks.apply)
        {:reply, {:ok, diff, warnings}, state}

      {:error, {:invalid, errors}} ->
        # Form errors, not config health: the running config is untouched and
        # still valid, so `last_load` must not start claiming otherwise.
        run_zero_arity(:after_rollback, callbacks.rollback)
        {:reply, {:error, errors}, state}

      {:error, {:write, reason}} ->
        run_zero_arity(:after_rollback, callbacks.rollback)
        {:reply, {:error, {:write, reason}}, state}
    end
  end

  # `after_commit:` right after the transaction commits and before this new
  # config is published or applied; `after_rollback:` on the arms where it did
  # not commit — see the moduledoc. Same rescue/catch shape as
  # `run_after_apply/2` and for the same reason: the caller's cleanup is the
  # caller's code running in this process, and a bug in it is not a reason for
  # the config server, and every camera it holds, to die over a save whose own
  # outcome is already decided.
  #
  # `after_rollback:` alone gets retried on failure (`retry_rollback/3` below):
  # it is undoing a step the write closure took outside the transaction (a
  # control tombstone ahead of the row delete it guards — see the moduledoc),
  # and nothing else will undo that marker before the next successful
  # `update/3` happens to revive it. `after_commit:` and `after_apply:` have no
  # equivalent debt — their config is already installed, so there is nothing
  # standing for a retry to clean up — and stay best-effort as before.
  defp run_zero_arity(_name, nil), do: :ok

  defp run_zero_arity(:after_rollback = name, fun), do: retry_rollback(name, fun, 1)

  defp run_zero_arity(name, fun) do
    case call_zero_arity(fun) do
      :ok -> :ok
      {:error, reason} -> log_zero_arity_error(name, reason, :error)
    end
  end

  # Bound low enough that a `CameraControl` restart (supervisor-paced, not
  # operator-paced) has cleared well before attempts run out.
  @rollback_retry_delay_ms 500
  @rollback_retry_max_attempts 10

  defp retry_rollback(name, fun, attempt) do
    case call_zero_arity(fun) do
      :ok ->
        :ok

      {:error, reason} when attempt < @rollback_retry_max_attempts ->
        log_zero_arity_error(name, reason, :warning)

        Process.send_after(
          self(),
          {:retry_callback, name, fun, attempt + 1},
          @rollback_retry_delay_ms
        )

        :ok

      {:error, reason} ->
        log_zero_arity_error(name, reason, :error)
    end
  end

  @impl true
  def handle_info({:retry_callback, name, fun, attempt}, state) do
    retry_rollback(name, fun, attempt)
    {:noreply, state}
  end

  defp call_zero_arity(fun) do
    fun.()
    :ok
  rescue
    e -> {:error, {:raise, e.__struct__}}
  catch
    kind, reason when is_atom(reason) -> {:error, {kind, reason}}
    kind, _reason -> {:error, {kind, :non_atom_exit}}
  end

  defp log_zero_arity_error(name, {:raise, struct}, level),
    do: Logger.log(level, "config: #{name} raised: #{inspect(struct)}")

  defp log_zero_arity_error(name, {kind, :non_atom_exit}, level),
    do: Logger.log(level, "config: #{name} #{kind}: non-atom exit")

  defp log_zero_arity_error(name, {kind, reason}, level) when is_atom(reason),
    do: Logger.log(level, "config: #{name} #{kind}: #{inspect(reason)}")

  # The caller's cleanup is the caller's code running in this process, and it
  # runs after the config is already installed: a bug in it is not a reason
  # for the config server, and every camera it holds, to die on a save that
  # succeeded. `catch` as well as `rescue` — a callback that exits would take
  # the server down just as effectively as one that raises.
  #
  # Only the shape is logged, never the message or a non-atom reason: the
  # failure carries whatever the callback was handed, and some carry a lot —
  # `Ecto.InvalidChangesetError`'s message embeds the whole changeset, camera
  # credentials included.
  defp run_after_apply(nil, _diff), do: :ok

  defp run_after_apply(fun, diff) do
    fun.(diff)
    :ok
  rescue
    e -> Logger.error("config: after_apply raised: #{inspect(e.__struct__)}")
  catch
    kind, reason when is_atom(reason) ->
      Logger.error("config: after_apply #{kind}: #{inspect(reason)}")

    kind, _reason ->
      Logger.error("config: after_apply #{kind}: non-atom exit")
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
  catch
    # Same reasoning one kind over: a closure's step outside the transaction is
    # a `GenServer.call` to a sibling (`CameraControl.tombstone/1`), which exits
    # while that sibling is restarting. An escaping exit would kill the fleet's
    # config server *and* skip `after_rollback:`, leaving the rolled-back row
    # tombstoned and dark. DBConnection has already rolled the transaction back
    # by the time it reaches here.
    :exit, reason -> {:error, {:write, {:exit, reason}}}
    :throw, value -> {:error, {:write, {:throw, value}}}
  end

  defp attempt(state, write_fun, reject) do
    with :ok <- call_write(write_fun, state.path),
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

  # A write that must validate against the file's globals needs the path the
  # server loads from, which only the server knows.
  defp call_write(fun, _path) when is_function(fun, 0), do: fun.()
  defp call_write(fun, path), do: fun.(path)

  # A per-camera fault skips the row on a *load*, so one drifted camera cannot
  # take the fleet down with it. On a save that row is the operator's own act:
  # its faults are form errors, and the store must not accept a row that would
  # only go dark. Another camera's skip is not this save's doing and does not
  # reject it.
  defp own_skips(reject, skipped),
    do: Enum.flat_map(List.wrap(reject), &Map.get(skipped, &1, []))

  # The ok arm shared by `:reload` and `{:update, _}`, so the four orderings
  # below cannot drift between the two paths. `after_apply` is `nil` on the
  # reload path — a reload has no caller write to hang cleanup off.
  defp apply_config(state, new_config, warnings, skipped, after_apply \\ nil) do
    diff = diff_cameras(state.config, new_config)
    # Before the apply: a tree the diff restarts may be rebuilt by its
    # supervisor at any point after, and must find this fleet, not the
    # last one.
    publish(state, new_config)
    # The wrap covers this post-commit prep as well as the apply itself, not
    # only the apply: `DataDir.ensure!/1` can raise (an unwritable new
    # data_dir), and the transaction is already committed here, so that raise
    # owes `after_apply:` (pruning a deleted camera's runtime state) exactly
    # as an apply that raises or exits does. The failure itself still
    # propagates and takes this server down as before — reconciling the
    # runtime owners against the config on its restart is the follow-up
    # (`.claude/plans/ui-camera-config/scratchpad.md`).
    try do
      # Newly spawned ports redirect logs into the (possibly changed)
      # data_dir, so its log subdir must already exist before the apply.
      Cairn.DataDir.ensure!(new_config.data_dir)
      # Before the cameras: detection is the in-VM engine, so the model a
      # restarted camera will open a stream on should already be the new
      # one. The call is asynchronous, so this is an ordering of sends
      # rather than of loads.
      state.apply_native.(new_config)
      state.apply_diff.(diff, new_config)
    after
      # Before the broadcast: a subscriber that reacts to `{:config_changed, _}`
      # by calling `get/1` shares this mailbox with the callback, and a prune
      # that blocks on another owner's call would otherwise make that read wait
      # behind cleanup the subscriber has no reason to know about.
      run_after_apply(after_apply, diff)
    end

    # A camera in an applied config is, by definition, not deleted: whatever
    # tombstoned its id — a delete this save rolled back later, a re-import,
    # another suite in the test run — is over once the fleet names it again,
    # so its control writes are accepted from here on. Caught because the
    # control server is a sibling that may be restarting.
    Enum.each(new_config.cameras, &revive_control/1)
    state = %{state | config: new_config, warnings: warnings, errors: [], skipped: skipped}
    Phoenix.PubSub.broadcast(Cairn.PubSub, Config.topic(), {:config_changed, diff})
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

  defp revive_control(%Config.Camera{id: id}) do
    Cairn.CameraControl.revive(id)
  catch
    :exit, _ -> :ok
  end

  # Overwriting a persistent term scans every process for references to the
  # old one — bounded here by boot plus the reload and save rate, both
  # operator paced. An ETS table owned by this server is the alternative if a
  # save rate ever makes that scan measurable.
  defp publish(%{snapshot: nil}, _config), do: :ok
  defp publish(%{snapshot: name}, config), do: :persistent_term.put(snapshot_key(name), config)

  defp source_fun(fun) when is_function(fun, 1), do: fun
  # A named capture, so the boundary error prints `&Mod.fun/1`, not a closure.
  defp source_fun({mod, fun}) when is_atom(mod) and is_atom(fun),
    do: Function.capture(mod, fun, 1)

  defp source_fun(other) do
    raise ArgumentError,
          "the config loader (`source:` opt or the :cairn, :config_loader app env) must be a " <>
            "1-arity fun or {module, function}, got: #{inspect(other)}"
  end

  @doc false
  @spec diff_cameras(Config.t(), Config.t()) :: diff()
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

  # Whether installing `new` over `old` would restart `camera_id`'s tree — the
  # camera diff's own test, public so a form can ask it of a candidate config
  # it has built but not written. False when either config is missing the
  # camera: an add or a remove is not a restart, and neither is a prediction
  # made against a config that could not be read.
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
