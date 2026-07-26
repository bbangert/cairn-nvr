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

  @doc "Camera ids currently registered for a given role."
  @spec ids_for_role(atom()) :: [String.t()]
  def ids_for_role(role) do
    Registry.select(__MODULE__, [
      {{{:"$1", role}, :_, :_}, [], [:"$1"]}
    ])
  end
end
