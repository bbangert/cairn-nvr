defmodule Cairn.Detect.Dispatch do
  @moduledoc """
  The one hop from a detection producer to a camera's tracker.

  Two producers reach it: `Cairn.PluginPort` / `Cairn.PluginGroupPort` for an
  external plugin's ndjson lines, `Cairn.Pipeline.DetectSink` for the in-VM NIF's
  frames. Each resolves `Cairn.Config.policy/2` off the per-frame path — at init
  and on refresh — and hands the result through here unmodified, so
  `Cairn.CameraTracker` never calls the config server per frame and both
  producers deliver the same pair.

  Plain functions in the caller's process, deliberately not a process of its
  own. The sink calls this between blocking `Cairn.Native.Host.push_frame/5` calls;
  a GenServer here would queue every camera's detections behind whichever one is
  in the model.
  """

  alias Cairn.CameraTracker
  alias Cairn.Config
  alias Cairn.Observation

  @doc """
  One observation to `camera`'s tracker, carrying `policy`.

  Tier-surface's tier-1/tier-2 fork belongs here: this is the only call both
  producers make, so the fork stays one site rather than one per producer.

  `opts[:tracker]` is the producers' injection seam — a process that receives
  the same `{:detections, …}` cast in place of the camera's own tracker. Absent
  (production) the batch goes to that camera's tracker, started on the first
  batch if it is not running yet.
  """
  @spec forward(Config.Camera.t(), map(), Observation.t(), keyword()) :: :ok
  def forward(%Config.Camera{} = camera, policy, %Observation{} = observation, opts \\ []) do
    CameraTracker.detections(Keyword.get(opts, :tracker), camera, policy, observation)
  end

  @doc """
  One push's worth of observations, in order.

  Delivery is a cast per observation from one process to one tracker, so list
  order is arrival order.
  """
  @spec forward_all(Config.Camera.t(), map(), [Observation.t()], keyword()) :: :ok
  def forward_all(%Config.Camera{} = camera, policy, observations, opts \\ []) do
    Enum.each(observations, &forward(camera, policy, &1, opts))
  end
end
