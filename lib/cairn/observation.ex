defmodule Cairn.Observation do
  @moduledoc """
  One decoded observation line from a plugin: what was seen in one frame of
  one camera's stream, with the timing and provenance the rest of the system
  needs to place it.

  Produced by `Cairn.PluginProtocol.decode_line/2` and completed by the port
  that owns the plugin process (`camera_id`, `plugin_instance`, and — for v0
  lines, which carry none of it — `epoch` and `observed_at`).

  Timing has two qualities. A v1 line carries `observed_at` from the plugin,
  captured next to the frame it describes (`:source`); a v0 line has no time
  at all, so the port stamps arrival (`:arrival`) and every offset derived
  from it inherits the plugin's queueing and scheduling latency.

  `media_ms` is `pts` in milliseconds of the stream's own clock. It is not
  comparable across epochs, and it is *not* an address into the recording:
  the mapping between plugin pts and fMP4 `tfdt` is undefined.

  `tracking` is not on the wire: it is the port's answer to "did this plugin
  declare the `object_tracking` capability in its `plugin.hello`?", and it is
  what decides whether `Cairn.Tracker` honours the objects' `track_id`s.
  """

  @type time_base :: {pos_integer(), pos_integer()}

  @type object :: %{
          label: String.t(),
          score: float(),
          bbox: [number()],
          track_id: String.t() | nil,
          observation_kind: String.t()
        }

  @type t :: %__MODULE__{
          camera_id: String.t() | nil,
          epoch: String.t() | nil,
          sequence: non_neg_integer() | nil,
          plugin_instance: String.t() | nil,
          pts: number(),
          time_base: time_base(),
          media_ms: float(),
          observed_at: DateTime.t() | nil,
          time_quality: :source | :arrival,
          objects: [object()],
          ended_tracks: [String.t()],
          invalid_objects: non_neg_integer(),
          tracking: boolean(),
          protocol: :v0 | :v1
        }

  defstruct camera_id: nil,
            epoch: nil,
            sequence: nil,
            plugin_instance: nil,
            pts: 0,
            time_base: {1, 90_000},
            media_ms: 0.0,
            observed_at: nil,
            time_quality: :arrival,
            objects: [],
            ended_tracks: [],
            invalid_objects: 0,
            tracking: false,
            protocol: :v0

  @doc "`pts` in milliseconds of the stream clock described by `time_base`."
  @spec media_ms(number(), time_base()) :: float()
  def media_ms(pts, {num, den}), do: pts / den * num * 1000

  @doc """
  Whether an object is evidence: `observation_kind == "detected"`.

  A `"tracked"` object is the plugin's own prediction for a track it did not
  detect in this frame. It keeps track state alive but must never be taken as
  proof that something is there. Takes a plain map so it also answers for
  tracker-tagged objects (and for v0 objects, which carry no kind).
  """
  @spec detected?(map()) :: boolean()
  def detected?(object), do: Map.get(object, :observation_kind, "detected") == "detected"
end
