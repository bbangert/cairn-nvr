defmodule Cairn.Artifacts do
  @moduledoc """
  Runtime files a release does not carry, stored as
  `<data_dir>/artifacts/<sha256>` and usable only once their bytes hash to
  that name. The set starts as the board's (`c:Cairn.Stage.Board.artifacts/1`)
  and grows through `want/1`.

  This process checks what is already on disk — synchronously and without the
  network, so that the config loaded right after it knows what is missing —
  and owns the status table. `Cairn.Artifacts.Fetcher` downloads the rest from
  late in the boot. A reader reads the table, filled under another name so
  that it is seen only complete, and never waits on a download. With no
  table, a store that has been up is taken to be restarting: each backend
  any of its artifacts is needed for, as published in `:persistent_term`, is
  unusable, its status unknown. One never started (as in tests) published
  nothing, and nothing is missing.

  An artifact with `env:` — the board's only, as `want/1` drops the key —
  names a variable. Unless the operator already set it, it is set to the
  file's path whether or not the file is there yet, so the board's preflight
  and the canary — a subprocess that inherits the VM's environment — see
  where it will be. Set by the operator, the artifact is overridden: the
  operator supplied the file, and it is neither fetched nor checked.
  """

  use GenServer

  require Logger

  alias Cairn.Config

  @type status :: :verified | :overridden | :missing

  @typedoc "One artifact as the table holds it; `failure` is the last fetch's, `nil` before one."
  @type entry :: %{
          name: String.t(),
          url: String.t(),
          sha256: String.t(),
          size: pos_integer() | nil,
          backend: String.t() | nil,
          path: Path.t(),
          status: status(),
          failure: String.t() | nil
        }

  @type unusable :: %{
          String.t() => [%{name: String.t(), failure: String.t() | nil | :restarting}]
        }

  @sha256 ~r/\A[0-9a-f]{64}\z/

  @doc """
  `name:` is the process and the table (default `Cairn.Artifacts`), `dir:`
  the store, `artifacts:` the initial set, `fetcher:` the process woken when
  any is missing. `enabled: false` starts nothing.
  """
  def start_link(opts) do
    if Keyword.get(opts, :enabled, true) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
    else
      :ignore
    end
  end

  @doc "The file for `sha256` once verified, or the operator's; else `nil`."
  @spec path(String.t(), atom()) :: Path.t() | nil
  def path(sha256, table \\ __MODULE__) do
    case lookup(table, String.downcase(sha256)) do
      %{status: status, path: path} when status in [:verified, :overridden] -> path
      _missing_or_unknown -> nil
    end
  end

  @doc """
  Each backend some missing artifact is needed for, with what is missing and
  the last fetch's failure (`nil` before the first attempt). With no table,
  see the moduledoc.
  """
  @spec unusable(atom()) :: unusable()
  def unusable(table \\ __MODULE__) do
    case entries(table) do
      nil -> :persistent_term.get({__MODULE__, table}, %{})
      entries -> entries |> Enum.filter(&(&1.status == :missing)) |> gated(& &1.failure)
    end
  end

  defp gated(entries, failure) do
    entries
    |> Enum.filter(&is_binary(&1.backend))
    |> Enum.group_by(& &1.backend, &%{name: &1.name, failure: failure.(&1)})
  end

  @doc """
  Adds artifacts to the set, without their `env:`: only the board's may export
  a variable. The fetcher is woken for any that are missing.
  """
  @spec want([map()], atom()) :: :ok
  def want(artifacts, server \\ __MODULE__) when is_list(artifacts),
    do: GenServer.cast(server, {:want, artifacts})

  @doc false
  @spec missing(atom()) :: [entry()]
  def missing(table \\ __MODULE__),
    do: Enum.filter(entries(table) || [], &(&1.status == :missing))

  @doc false
  @spec record(atom(), String.t(), :verified | {:failed, String.t()}) :: :ok
  def record(server, sha256, outcome), do: GenServer.call(server, {:record, sha256, outcome})

  @doc false
  @spec sha256_file(Path.t()) :: String.t()
  def sha256_file(path) do
    path
    |> File.stream!(1_048_576)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  # No table — this process not started, restarting, or stopping mid-read —
  # raises, which a config load must not.
  defp lookup(table, sha256) do
    case :ets.lookup(table, sha256) do
      [{_sha, entry}] -> entry
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp entries(table) do
    Enum.map(:ets.tab2list(table), &elem(&1, 1))
  rescue
    ArgumentError -> nil
  end

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    dir = Keyword.get_lazy(opts, :dir, &default_dir/0)

    artifacts =
      Keyword.get_lazy(opts, :artifacts, fn -> Cairn.Board.module().artifacts(%{}) end)

    restarted? = :persistent_term.get({__MODULE__, name}, nil) != nil

    filling =
      :ets.new(:"#{name} filling", [:named_table, :set, :protected, read_concurrency: true])

    case File.mkdir_p(dir) do
      :ok -> remove_partials(dir)
      {:error, reason} -> Logger.error("artifacts: cannot create #{dir}: #{inspect(reason)}")
    end

    state = %{
      table: filling,
      dir: dir,
      fetcher: Keyword.get(opts, :fetcher, Cairn.Artifacts.Fetcher)
    }

    Enum.each(artifacts, &register(state, &1))
    state = %{state | table: :ets.rename(filling, name)}
    publish(state)

    # A first start's `:work` is lost at boot, where the fetcher starts later
    # and looks for itself. A restart's `:reload` fetches too, and reloads: a
    # reload refused while this process was down stands until another.
    cond do
      restarted? -> GenServer.cast(state.fetcher, :reload)
      missing(name) != [] -> GenServer.cast(state.fetcher, :work)
      true -> :ok
    end

    {:ok, state}
  end

  # What `unusable/1` answers with no table. Never erased: it is what marks
  # this store as having been up.
  defp publish(state) do
    gated = gated(entries(state.table), fn _entry -> :restarting end)
    :persistent_term.put({__MODULE__, state.table}, gated)
  end

  # What the Repo resolves too: the env override, else the config file's.
  # Absolute, as the exported variable is read from other working directories.
  defp default_dir,
    do: Path.expand(Path.join(Config.resolve_data_dir(Config.default_path()), "artifacts"))

  # A download the node died during, or one cut short by a restart of this
  # process (which then fails as having written no file, and is retried); the
  # fetcher writes nothing else here.
  defp remove_partials(dir),
    do: dir |> Path.join("*.part") |> Path.wildcard() |> Enum.each(&File.rm/1)

  @impl true
  def handle_cast({:want, artifacts}, state) do
    for artifact <- artifacts,
        do: register(state, if(is_map(artifact), do: Map.delete(artifact, :env), else: artifact))

    publish(state)
    if missing(state.table) != [], do: GenServer.cast(state.fetcher, :work)
    {:noreply, state}
  end

  @impl true
  def handle_call({:record, sha256, outcome}, _from, state) do
    case :ets.lookup(state.table, sha256) do
      [{^sha256, entry}] -> :ets.insert(state.table, {sha256, recorded(entry, outcome)})
      [] -> :ok
    end

    {:reply, :ok, state}
  end

  defp recorded(entry, :verified), do: %{entry | status: :verified, failure: nil}
  defp recorded(entry, {:failed, failure}), do: %{entry | status: :missing, failure: failure}

  # An artifact already in the table keeps its status: a second `want/1` of a
  # verified file must not hash it again or forget it was overridden.
  defp register(state, %{name: name, url: url, sha256: sha256} = artifact)
       when is_binary(name) and is_binary(url) and is_binary(sha256) do
    sha256 = String.downcase(sha256)
    size = Map.get(artifact, :size)
    env = Map.get(artifact, :env)

    cond do
      not Regex.match?(@sha256, sha256) ->
        Logger.error("artifacts: #{name}: #{inspect(sha256)} is not a sha256; ignored")

      not well_formed?(size, env) ->
        Logger.error("artifacts: #{name}: size must be a positive integer, env a string; ignored")

      :ets.member(state.table, sha256) ->
        :ok

      true ->
        path = Path.join(state.dir, sha256)

        entry = %{
          name: name,
          url: url,
          sha256: sha256,
          size: size,
          backend: Map.get(artifact, :backend),
          path: path,
          status: :missing,
          failure: nil
        }

        :ets.insert(state.table, {sha256, checked(entry, env)})
    end
  end

  # Never the whole entry: its URL can carry a credential.
  defp register(_state, %{name: name}) when is_binary(name),
    do: Logger.error("artifacts: #{name} lacks a url or sha256; ignored")

  defp register(_state, _artifact),
    do: Logger.error("artifacts: an entry without a name, url or sha256 was ignored")

  defp well_formed?(size, env),
    do: (size == nil or (is_integer(size) and size > 0)) and (env == nil or is_binary(env))

  # The variable is compared with this store's own path rather than tested
  # for presence: after a restart of this process it is still set, by the
  # previous instance, and is not the operator's.
  defp checked(entry, env) when is_binary(env) do
    case System.get_env(env) do
      nil ->
        System.put_env(env, entry.path)
        on_disk(entry)

      path when path == entry.path ->
        on_disk(entry)

      path ->
        Logger.info("artifacts: #{entry.name} is the operator's #{path} (#{env}); not fetched")
        %{entry | path: path, status: :overridden}
    end
  end

  defp checked(entry, nil), do: on_disk(entry)

  # By `lstat`: a symlink here could point at a file swapped after the check.
  defp on_disk(entry) do
    case File.lstat(entry.path) do
      {:error, :enoent} ->
        entry

      {:ok, %File.Stat{type: :regular}} ->
        if sha256_file(entry.path) == entry.sha256,
          do: %{entry | status: :verified},
          else: remove(entry, "does not hash to its name")

      {:ok, %File.Stat{type: type}} ->
        remove(entry, "is a #{type}, not a regular file")

      {:error, reason} ->
        Logger.error("artifacts: cannot check #{entry.path}: #{:file.format_error(reason)}")
        entry
    end
  rescue
    # Unreadable, at open or part-way: missing, so the fetch replaces it or
    # records why it cannot.
    error in [File.Error, IO.StreamError] ->
      Logger.error("artifacts: cannot check #{entry.path}: #{Exception.message(error)}")
      entry
  end

  defp remove(entry, why) do
    case File.rm_rf(entry.path) do
      {:ok, _removed} ->
        Logger.warning("artifacts: #{entry.path} #{why}; deleted")

      {:error, reason, _path} ->
        Logger.error(
          "artifacts: #{entry.path} #{why} and cannot be removed " <>
            "(#{:file.format_error(reason)}); it stays unusable"
        )
    end

    entry
  end
end
