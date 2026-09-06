defmodule Cairn.ConfigSubscription do
  @moduledoc """
  A config-change subscription that survives a `Cairn.PubSub` restart.

  The runtime table owners and `Cairn.CameraReaper` subscribe once, in
  `init/1`, and prune only when a `{:config_changed, _}` message arrives. A
  `Phoenix.PubSub` restart drops every subscription the survivors held, and a
  subscribe-once owner never learns of it: it keeps a dead subscription and
  silently stops pruning/reaping, so a re-created camera can inherit a stale
  overlay or a deleted one's producer can outlive it. Monitoring the PubSub
  process and re-subscribing on its `:DOWN` closes that gap per owner, without
  the ordering coupling a supervision group would impose.

  `Process.whereis(Cairn.PubSub)` is the live registered pid; it dies and is
  re-registered when the PubSub child restarts, so monitoring it and
  re-subscribing on `:DOWN` sees exactly that restart.
  """

  # A PubSub restart between the subscribe and the monitor would leave the owner
  # subscribed through one instance and monitoring another, so the `:DOWN` for
  # the instance the subscription actually went through would never arrive.
  # Monitor a captured pid first, subscribe, then confirm the registered pid did
  # not move across the pair; if it did, redo. Restarts are rare, so this
  # converges at once. (A dead captured pid makes `Process.monitor/1` deliver an
  # immediate `:DOWN`, which is harmless — it just drives one re-subscribe.)
  @doc "Subscribes to config changes and monitors PubSub; returns the monitor ref."
  @spec subscribe() :: reference()
  def subscribe do
    pid = pubsub()
    ref = Process.monitor(pid)
    Cairn.Config.Server.subscribe()

    if Process.whereis(Cairn.PubSub) == pid do
      ref
    else
      Process.demonitor(ref, [:flush])
      subscribe()
    end
  end

  @doc """
  Handles a monitor `:DOWN`. If it is the PubSub monitor `ref`, re-subscribes
  and re-monitors, returning `{:ok, new_ref}`; any other message or ref is
  `:other` for the owner to handle itself.
  """
  @spec handle_down(term(), reference()) :: {:ok, reference()} | :other
  def handle_down({:DOWN, ref, :process, _pid, _reason}, ref), do: {:ok, subscribe()}
  def handle_down(_msg, _ref), do: :other

  # During a PubSub restart the name is briefly unregistered (old pid gone, new
  # one not yet up). Re-subscribing in that window must wait it out rather than
  # crash the owner; only a PubSub that never comes back raises.
  @wait_ms 20
  @max_tries 100
  @doc """
  Runs `fun` against the currently published membership, or nothing when no
  snapshot is published. Called after a re-subscribe: a config change that
  landed while this owner's subscription was down would otherwise be missed
  until the next one, so the owner reconciles its own table (or reaps) against
  the current fleet to catch anything it slept through.
  """
  @spec reconcile((MapSet.t(String.t()) -> any())) :: :ok
  def reconcile(fun) do
    case Cairn.Config.Server.known_ids() do
      %MapSet{} = known -> _ = fun.(known)
      nil -> :ok
    end

    :ok
  end

  defp pubsub(tries \\ @max_tries) do
    case Process.whereis(Cairn.PubSub) do
      pid when is_pid(pid) ->
        pid

      nil when tries > 0 ->
        Process.sleep(@wait_ms)
        pubsub(tries - 1)

      nil ->
        raise "Cairn.PubSub is not running: it must start before its config-change subscribers"
    end
  end
end
