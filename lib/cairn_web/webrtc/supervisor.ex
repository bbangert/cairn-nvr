defmodule CairnWeb.WebRTC.Supervisor do
  @moduledoc """
  DynamicSupervisor for viewer WebRTC sessions — deliberately separate
  from `Cairn.EventSupervisor` (event recording) and capped, so a
  signaling flood can exhaust neither the recording pipeline nor the
  machine (each session owns a PeerConnection + UDP sockets).
  """

  use DynamicSupervisor

  @max_sessions 32

  def start_link(opts), do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one, max_children: @max_sessions)
  end
end
