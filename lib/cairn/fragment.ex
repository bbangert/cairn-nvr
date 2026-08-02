defmodule Cairn.Fragment do
  @moduledoc """
  One complete fmp4 media fragment (`moof` + `mdat`) as parsed from a
  camera's ffmpeg stdout.

  `pts` is the fragment's baseMediaDecodeTime in `timescale` units (from
  `tfdt`); `duration_ms` is derived from the `trun`/`tfhd` sample durations.
  `seq` is stamped by the demuxer per ffmpeg session and re-stamped by the
  ring buffer with a monotonic per-camera counter.

  `keyframe?` means **this fragment's first sample is a sync sample** — an
  IDR, something a decoder can be handed cold. It is not "this fragment
  contains a keyframe": a fragment can hold one part-way through and still be
  false here, because what a file starting at this fragment would be missing is
  the samples *before* it. A camera whose GOP is longer than its fragment
  duration produces runs of false ones (`Cairn.EventExtractor` will not open a
  clip on those; see its moduledoc).

  It defaults to `true` because the failure directions are not symmetric: a
  fragment wrongly marked keyframe-headed costs a leading empty edit in one
  clip, while one wrongly marked otherwise is video an NVR silently declines to
  record. `Cairn.MP4.Demuxer` — the only producer in `lib/` — always computes
  it, and answers `false` only on a positive reading of the
  `sample_is_non_sync_sample` bit or on a fragment carrying no samples at all;
  every reading it cannot make comes back `true`.
  """

  @enforce_keys [:camera_id, :seq, :pts, :data]
  defstruct [
    :camera_id,
    :seq,
    :pts,
    :data,
    duration_ms: 0,
    timescale: 90_000,
    keyframe?: true
  ]

  @type t :: %__MODULE__{
          camera_id: String.t(),
          seq: non_neg_integer(),
          pts: non_neg_integer(),
          duration_ms: non_neg_integer(),
          timescale: pos_integer(),
          keyframe?: boolean(),
          data: binary()
        }
end
