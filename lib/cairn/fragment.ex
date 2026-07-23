defmodule Cairn.Fragment do
  @moduledoc """
  One complete fmp4 media fragment (`moof` + `mdat`) as parsed from a
  camera's ffmpeg stdout.

  `pts` is the fragment's baseMediaDecodeTime in `timescale` units (from
  `tfdt`); `duration_ms` is derived from the `trun`/`tfhd` sample durations.
  `seq` is stamped by the demuxer per ffmpeg session and re-stamped by the
  ring buffer with a monotonic per-camera counter.
  """

  @enforce_keys [:camera_id, :seq, :pts, :data]
  defstruct [:camera_id, :seq, :pts, :data, duration_ms: 0, timescale: 90_000]

  @type t :: %__MODULE__{
          camera_id: String.t(),
          seq: non_neg_integer(),
          pts: non_neg_integer(),
          duration_ms: non_neg_integer(),
          timescale: pos_integer(),
          data: binary()
        }
end
