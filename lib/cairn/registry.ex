defmodule Cairn.Registry do
  @moduledoc """
  Unique process registry for per-camera processes, keyed by
  `{camera_id, role}` (e.g. `{"front_door", :ring_buffer}`).
  """

  require Logger

  def child_spec(_opts) do
    Registry.child_spec(keys: :unique, name: __MODULE__)
  end

  @typedoc "Process role: an atom, or `{:extractor, event_id}` for extractors."
  @type role :: atom() | {atom(), String.t()}

  @doc "Via-tuple for registering/looking up a per-camera process."
  @spec via(String.t(), role()) :: {:via, Registry, {module(), {String.t(), role()}}}
  def via(camera_id, role), do: {:via, Registry, {__MODULE__, {camera_id, role}}}

  @doc """
  Registers the calling process under `{camera_id, role}`.

  For processes that cannot be started with a `name:` — a membrane element is
  one. The registry unregisters on the process's DOWN, so nothing has to be
  undone on teardown.
  """
  @spec register(String.t(), role()) :: {:ok, pid()} | {:error, {:already_registered, pid()}}
  def register(camera_id, role), do: Registry.register(__MODULE__, {camera_id, role}, nil)

  @spec whereis(String.t(), role()) :: pid() | nil
  def whereis(camera_id, role) do
    case Registry.lookup(__MODULE__, {camera_id, role}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Blocks (bounded) until `{camera_id, role}` is unregistered.

  Registry unregisters on the process DOWN message, slightly after a
  synchronous `terminate_child` returns. A stop that is immediately
  followed by a re-sync must wait it out, or the sync reads the dead
  process as still running and skips the restart.
  """
  @spec await_unregistered(String.t(), role(), non_neg_integer()) :: :ok
  def await_unregistered(camera_id, role, attempts \\ 200) do
    case whereis(camera_id, role) do
      nil ->
        :ok

      _pid when attempts > 0 ->
        Process.sleep(5)
        await_unregistered(camera_id, role, attempts - 1)

      pid ->
        Logger.warning("#{inspect({camera_id, role})}: still registered to #{inspect(pid)}")
        :ok
    end
  end

  @doc """
  Every registered extractor as `{camera_id, event_id, pid}`.

  Its own selector because the extractor role is the one keyed per event
  rather than per camera, so `ids_for_role/1`'s exact-role match cannot name
  it and one camera can hold several at once.
  """
  @spec extractors() :: [{String.t(), String.t(), pid()}]
  def extractors do
    Registry.select(__MODULE__, [
      {{{:"$1", {:extractor, :"$2"}}, :"$3", :_}, [], [{{:"$1", :"$2", :"$3"}}]}
    ])
  end

  @doc "Camera ids currently registered for a given role."
  @spec ids_for_role(atom()) :: [String.t()]
  def ids_for_role(role) do
    Registry.select(__MODULE__, [
      {{{:"$1", role}, :_, :_}, [], [:"$1"]}
    ])
  end

  @doc "Camera ids currently registered under any of `roles`, deduplicated."
  @spec camera_ids([atom()]) :: [String.t()]
  def camera_ids(roles) do
    roles |> Enum.flat_map(&ids_for_role/1) |> Enum.uniq()
  end
end
