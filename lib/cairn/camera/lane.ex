defmodule Cairn.Camera.Lane do
  @moduledoc """
  A camera's event workers, `:one_for_one` — the `:lane` child of
  `Cairn.Camera`, ahead of `:media`.

  Ahead, so a media restart touches none of them: the pipeline reaches these
  workers by resolving their Registry names per batch and casting, holding no
  pid and no monitor, so a worker restarting is invisible to it and the media
  never depends on the lane. `:one_for_one`, so a single worker's crash
  restarts only itself, restoring from its checkpoint, isolated from the other
  workers and from the media.

  Empty for now: the presence and tracking workers move in here from their
  shared pools in the next two steps (`design-supervision.md`, S2 and S3).
  """

  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts)

  @impl true
  def init(_opts), do: Supervisor.init([], strategy: :one_for_one)
end
