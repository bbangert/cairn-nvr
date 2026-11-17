defmodule Cairn.Artifacts.Fetcher do
  @moduledoc """
  Downloads what `Cairn.Artifacts` has missing, one at a time, and reloads the
  config after each file it verifies: a config refused for want of the file
  loads once it is there. A failure is recorded on the artifact, for the
  config error to name, and reloads when its text changed, since only a load
  refreshes that error; the missing set is tried again after a backoff of 5 s
  doubling to 5 min, for as long as the node runs.

  Nothing a fetch does may crash this process: the application's top
  supervisor allows three restarts in five seconds and takes the node down on
  the fourth crash, and an offline boot would fail every fetch that fast. The
  fetch function runs in a task, so one that raises, throws, exits, hangs or
  takes a linked process down with it costs only that attempt; verifying,
  moving the file into place and the reload run here, and catch what they
  can raise.

  `after_boot: true` holds all of it until `boot_done/1`: a reload landing
  while `Cairn.Boot` reconciles would start cameras that Boot's own sync, of
  the config it read before, then stops.
  """

  use GenServer

  require Logger

  alias Cairn.Artifacts
  alias Cairn.Artifacts.HTTP
  alias Cairn.Config.Server

  @initial_backoff_ms 5_000
  @max_backoff_ms 300_000
  # Past `Cairn.Artifacts.HTTP`'s own five minutes, so its timeout is the one
  # recorded; this is the backstop for a fetch function that has none.
  @attempt_timeout_ms 310_000
  @max_failure 300

  @doc """
  `fetch:` is `(artifact, path) -> :ok | {:error, reason}`, writing the file to
  `path`; `reload:` is called after each verified file and each changed
  failure. `artifacts:` names the `Cairn.Artifacts` server. `after_boot: true`
  waits for `boot_done/1`. `enabled: false` starts nothing.
  """
  def start_link(opts) do
    if Keyword.get(opts, :enabled, true) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
    else
      :ignore
    end
  end

  @doc "Ends an `after_boot: true` hold, also for any restart: Boot calls it once."
  @spec boot_done(atom()) :: :ok
  def boot_done(server \\ __MODULE__) do
    :persistent_term.put({__MODULE__, :boot_done, server}, true)
    GenServer.cast(server, :boot_done)
  end

  @impl true
  def init(opts) do
    state = %{
      artifacts: Keyword.get(opts, :artifacts, Artifacts),
      fetch: Keyword.get(opts, :fetch, &HTTP.fetch/2),
      reload: Keyword.get(opts, :reload, &Server.reload/0),
      task_supervisor: Keyword.get(opts, :task_supervisor, Cairn.TaskSupervisor),
      initial_backoff: Keyword.get(opts, :initial_backoff_ms, @initial_backoff_ms),
      max_backoff: Keyword.get(opts, :max_backoff_ms, @max_backoff_ms),
      attempt_timeout: Keyword.get(opts, :attempt_timeout_ms, @attempt_timeout_ms),
      held: held?(opts),
      backoff: nil,
      retry: nil
    }

    {:ok, %{state | backoff: state.initial_backoff}, {:continue, :work}}
  end

  defp held?(opts) do
    done = {__MODULE__, :boot_done, Keyword.get(opts, :name, __MODULE__)}
    Keyword.get(opts, :after_boot, false) and not :persistent_term.get(done, false)
  end

  @impl true
  def handle_continue(:work, state), do: {:noreply, work(state)}

  @impl true
  def handle_cast(:work, state), do: {:noreply, work(state)}
  def handle_cast(:boot_done, state), do: {:noreply, work(%{state | held: false})}
  def handle_cast(_message, state), do: {:noreply, state}

  @impl true
  def handle_info({:retry, ref}, %{retry: {_timer, ref}} = state), do: {:noreply, work(state)}

  # A retry a later pass superseded; anything unexpected.
  def handle_info(_message, state), do: {:noreply, state}

  defp work(%{held: true} = state), do: state

  # Forgetting the armed retry, fired or not, leaves any message of it in the
  # mailbox matching nothing: one chain of retries, never two.
  defp work(state) do
    with {timer, _ref} <- state.retry, do: Process.cancel_timer(timer)

    results =
      for entry <- Artifacts.missing(state.artifacts), do: attempt(state, entry)

    if Enum.all?(results, &(&1 == :ok)) do
      %{state | retry: nil, backoff: state.initial_backoff}
    else
      ref = make_ref()
      timer = Process.send_after(self(), {:retry, ref}, state.backoff)
      %{state | retry: {timer, ref}, backoff: min(state.backoff * 2, state.max_backoff)}
    end
  end

  defp attempt(state, entry) do
    partial = "#{entry.path}.#{System.unique_integer([:positive])}.part"

    result =
      try do
        with :ok <- mkdir(Path.dirname(entry.path)),
             :ok <- fetch(state, entry, partial),
             :ok <- verify(entry, partial),
             do: rename(partial, entry.path)
      rescue
        # Hashing a file that became unreadable under it, at open or part-way.
        error in [File.Error, IO.StreamError] -> {:error, Exception.message(error)}
      end

    _ = File.rm(partial)
    outcome(state, entry, result)
  end

  defp outcome(state, entry, :ok) do
    Logger.info("artifacts: #{entry.name} fetched and verified (#{entry.sha256})")
    record(state, entry, :verified)
    reload(state, entry, :verified)
    :ok
  end

  defp outcome(state, entry, {:error, failure}) do
    Logger.warning(
      "artifacts: #{entry.name} not fetched from #{loggable(entry.url)}: #{failure}; " <>
        "retrying in #{div(state.backoff, 1000)} s"
    )

    record(state, entry, {:failed, failure})
    if failure != entry.failure, do: reload(state, entry, :failed)
    :error
  end

  # A query or userinfo can carry a credential.
  defp loggable(url) do
    %URI{scheme: scheme, host: host, path: path} = URI.parse(url)
    "#{scheme}://#{host}#{path}"
  end

  defp mkdir(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, "cannot create #{dir}: #{:file.format_error(reason)}"}
    end
  end

  defp fetch(state, entry, partial) do
    artifact = Map.take(entry, [:name, :url, :sha256, :size])
    fetch = state.fetch

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        guarded(fn -> fetch.(artifact, partial) end)
      end)

    case Task.yield(task, state.attempt_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} -> {:error, describe(reason)}
      {:ok, other} -> {:error, "the fetch answered #{describe(other)}"}
      {:exit, reason} -> {:error, "the fetch exited: #{describe(reason)}"}
      nil -> {:error, "the fetch took longer than #{div(state.attempt_timeout, 1000)} s"}
    end
  catch
    # The task supervisor itself gone.
    kind, reason -> {:error, "the fetch could not start: #{describe({kind, reason})}"}
  end

  defp guarded(fun) do
    fun.()
  rescue
    error -> {:error, "the fetch raised: " <> Exception.message(error)}
  catch
    :throw, value -> {:error, "the fetch threw #{describe(value)}"}
    :exit, reason -> {:error, "the fetch exited: #{describe(reason)}"}
  end

  defp verify(entry, partial) do
    with {:ok, %File.Stat{size: size}} <- File.stat(partial),
         :ok <- size_matches(entry.size, size),
         sha256 when sha256 == entry.sha256 <- Artifacts.sha256_file(partial) do
      :ok
    else
      {:error, :enoent} -> {:error, "the fetch reported success but wrote no file"}
      {:error, reason} when is_atom(reason) -> {:error, to_string(:file.format_error(reason))}
      {:error, _message} = error -> error
      sha256 when is_binary(sha256) -> {:error, "the download hashes to #{sha256}"}
    end
  end

  defp size_matches(nil, _size), do: :ok
  defp size_matches(size, size), do: :ok

  defp size_matches(expected, size),
    do: {:error, "the download is #{size} bytes, not #{expected}"}

  defp rename(from, to) do
    case File.rename(from, to) do
      :ok -> :ok
      {:error, reason} -> {:error, "cannot move it into place: #{:file.format_error(reason)}"}
    end
  end

  # Out of a crash-proof loop, a dead or restarting store is an outcome to log
  # rather than an exit to propagate.
  defp record(state, entry, outcome) do
    Artifacts.record(state.artifacts, entry.sha256, outcome)
  catch
    :exit, reason ->
      Logger.warning("artifacts: could not record #{entry.name}: #{describe(reason)}")
  end

  # After a failure the reload only refreshes the config error, so a refusal
  # is its expected answer and a success says nothing worth a line.
  defp reload(state, entry, cause) do
    case state.reload.() do
      {:ok, _diff, _warnings} when cause == :verified ->
        Logger.info("artifacts: config reloaded with #{entry.name} in place")

      {:error, errors} when is_list(errors) and cause == :verified ->
        Logger.warning(
          "artifacts: config reload after #{entry.name} refused, " <>
            "with #{length(errors)} error(s) the config server logs"
        )

      {:ok, _diff, _warnings} ->
        :ok

      {:error, errors} when is_list(errors) ->
        :ok

      other ->
        Logger.warning("artifacts: config reload after #{entry.name} answered #{describe(other)}")
    end
  rescue
    error ->
      Logger.warning(
        "artifacts: config reload after #{entry.name} raised: #{Exception.message(error)}"
      )
  catch
    kind, reason ->
      Logger.warning(
        "artifacts: config reload after #{entry.name} failed: #{describe({kind, reason})}"
      )
  end

  # Every failure lands in a config error an operator reads: short, and never
  # a response body or a stack trace.
  defp describe(reason) when is_binary(reason), do: String.slice(reason, 0, @max_failure)

  defp describe({%{__exception__: true} = error, stack}) when is_list(stack),
    do: describe(Exception.message(error))

  defp describe(reason),
    do: reason |> inspect(limit: 8, printable_limit: 120) |> String.slice(0, @max_failure)
end
