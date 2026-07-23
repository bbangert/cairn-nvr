defmodule Cairn.Registry do
  @moduledoc """
  Unique process registry for per-camera processes, keyed by
  `{camera_id, role}` (e.g. `{"front_door", :ring_buffer}`).
  """

  def child_spec(_opts) do
    Registry.child_spec(keys: :unique, name: __MODULE__)
  end

  @doc "Via-tuple for registering/looking up a per-camera process."
  @spec via(String.t(), atom()) :: {:via, Registry, {module(), {String.t(), atom()}}}
  def via(camera_id, role), do: {:via, Registry, {__MODULE__, {camera_id, role}}}

  @spec whereis(String.t(), atom()) :: pid() | nil
  def whereis(camera_id, role) do
    case Registry.lookup(__MODULE__, {camera_id, role}) do
      [{pid, _}] -> pid
      [] -> nil
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
