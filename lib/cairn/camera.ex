defmodule Cairn.Camera do
  @moduledoc """
  Per-camera supervision tree (`:rest_for_one`).

  Child order: `RingBuffer` -> `FFmpegPort` -> (`PluginPort`) -> (`RTPHub`).
  Ring death restarts ffmpeg (a fresh ring is empty anyway); ffmpeg death
  restarts only the downstream consumers of its UDP outputs.

  Phase 1: skeleton with no children yet; registers under
  `{camera_id, :camera}` so config reloads can find and stop it.
  """

  use Supervisor

  def start_link(opts) do
    cam = Keyword.fetch!(opts, :camera)
    Supervisor.start_link(__MODULE__, opts, name: Cairn.Registry.via(cam.id, :camera))
  end

  @impl true
  def init(_opts) do
    children = []

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
