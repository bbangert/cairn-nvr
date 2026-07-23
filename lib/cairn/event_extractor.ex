defmodule Cairn.EventExtractor do
  @moduledoc """
  One `:temporary` process per active event, writing the clip to disk.

  Phase 4 scaffold: registers under `{camera_id, {:extractor, event_id}}`
  and honors the start/finalize API the aggregator drives. Phase 5 adds the
  index row, ring drain, fragment streaming and fsync policy.
  """

  use GenServer, restart: :temporary

  def start_link(opts) do
    camera = Keyword.fetch!(opts, :camera)
    event = Keyword.fetch!(opts, :event)

    GenServer.start_link(__MODULE__, opts,
      name: Cairn.Registry.via(camera.id, {:extractor, event.id})
    )
  end

  @doc "Starts an extractor under `Cairn.EventSupervisor`."
  @spec start(Cairn.Config.Camera.t(), Cairn.Event.t()) :: DynamicSupervisor.on_start_child()
  def start(camera, event) do
    DynamicSupervisor.start_child(
      Cairn.EventSupervisor,
      {__MODULE__, camera: camera, event: event}
    )
  end

  @doc "Tells the extractor to close the clip and exit normally."
  @spec finalize(pid() | nil, Cairn.Event.t()) :: :ok
  def finalize(nil, _event), do: :ok
  def finalize(pid, event), do: GenServer.cast(pid, {:finalize, event})

  @impl true
  def init(opts) do
    {:ok, %{camera: Keyword.fetch!(opts, :camera), event: Keyword.fetch!(opts, :event)}}
  end

  @impl true
  def handle_cast({:finalize, _event}, state) do
    {:stop, :normal, state}
  end
end
