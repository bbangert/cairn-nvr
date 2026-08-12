defmodule Cairn.ObservationClock do
  @moduledoc """
  Derives `Cairn.Observation.at_ms`, the one clock the tracker decides on.

  A plugin's `media_ms` is its stream's own `pts`: it restarts with every
  ffmpeg run, it can stall or rewind while the plugin keeps emitting, and it is
  the plugin's to move. The host's monotonic clock has none of those problems
  and knows nothing about which frame a line describes. `at_ms` is the first
  anchored to the second: media time carries the *spacing* between frames, and
  the host clock carries the *bound*.

  One of these per camera, held by what ingests that camera's detections —
  `Cairn.Pipeline.DetectSink`, whose detect branch now outlives session
  boundaries; the epoch-change re-anchor below is the designed path across
  them. `reset/1` is for a holder that replaces its producer while tracking
  time continues; nothing on the live path does that anymore, and it stays
  for the contract it documents.

  ## The clamp

      at_ms = max(prev + @floor_ms, min(anchor_ms + media_delta, now_ms))

  `anchor_ms` is where tracking time was pinned at the observation the current
  stretch was anchored on — the host's `now_ms` at the first observation of an
  epoch, or the clock's own continuity below — and `media_delta` is that
  observation's `media_ms` subtracted from this one's, so between two
  re-anchorings `at_ms` advances exactly as media time does. That is what keeps
  every bound the tracker is tuned with (`max_unseen_ms`,
  `stationary_after_ms`) meaning what it meant when they were media-time
  bounds. The two clamps bound the two ways a plugin's pts lies:

    * `min(…, now_ms)` — media time may not run ahead of the host. A pts that
      jumps forward, or a stream replayed faster than real time, would
      otherwise age every track by the jump and expire the scene at once. It is
      also what bounds the catching-up after a re-anchor at continuity below:
      tracking time runs at full media rate until it reaches the host's clock,
      and then no further.
    * `max(prev + @floor_ms, …)` — media time may neither freeze nor rewind.
      A stalled pts is the case the old host-clock backstop existed for: with
      a frozen `media_delta` nothing would ever reach an unseen bound, and the
      tracks of a dead stream would live forever. The floor costs the guarantee
      its precision — on a fully stalled pts `at_ms` creeps by a millisecond per
      *observation* rather than at the host's rate, so a track still retires but
      no faster than the plugin's frame rate lets it — and it is what makes the
      clock strictly increasing, which the tracker's arithmetic relies on
      (`Cairn.Tracker` floors no elapsed time at zero). It is also the only
      thing that can put `at_ms` *past* `now_ms`, and only for a plugin
      emitting two lines inside one host millisecond — more than a thousand a
      second.

  The anchor is re-taken on an epoch change, on a backwards `media_ms` within
  one epoch, and on the first observation after `reset/1`, and those are the
  only three things that re-take it. What they anchor *to* differs, and the
  asymmetry is deliberate:

    * **A rewind inside one epoch** (the producer's pts restarting under a
      still-current epoch — a recorded v1 plugin's inner ffmpeg respawn is the
      archetype) and **a producer swap** (`reset/1`) anchor
      at *continuity*: `at_ms + @floor_ms` against this observation's
      `media_ms`, so tracking time resumes at full media rate from where it
      already was and climbs back towards the host under the clamp above.
      Anchoring at `now_ms` instead would hand the next observation the whole
      lag the stall had accumulated in one step — every live track's
      `at_ms - last_seen_ms` inflating by it at once, which at a few seconds of
      `max_unseen_ms` expires the whole scene as `:unseen` and mints fresh
      identities for what is still standing there. The rewind is caught here
      rather than left to the floor because `anchored` otherwise sits below
      `at_ms` for as long as it takes media time to climb back, which is
      minutes of creeping a millisecond a line.
    * **An epoch change** anchors at `now_ms`. Nothing observed that gap:
      `Cairn.CameraTracker` suspends the live set at the cut, and the
      suspension and adoption windows it then waits out are elapsed times on
      this clock, so a real outage has to age them. Continuity there would make
      a 30 s dropout read as one millisecond and hold every adoption window
      open for as long as the stream stayed down. (The floor still applies: in
      the narrow case where creep left the previous stamp at or past `now_ms`,
      the first stamp of the new epoch is `prev + @floor_ms`, not `now_ms`.)

  `at_ms` is derived from the host's monotonic clock, and nothing but the
  floor's creep can put it ahead of one, which is what makes stamps comparable
  across an epoch change, a plugin respawn and a port restart. A respawn carries `at_ms` over
  (`reset/1`), and a clock from `new/0` takes its first stamp at `now_ms` — at
  or past anything a clock that ran before it could have stamped, there being
  no earlier stamp of its own to continue from. That is what lets a
  `Cairn.CameraTracker` — which outlives every one of them — subtract two
  `at_ms` from either side of a stream reset and get an elapsed time rather
  than garbage.
  """

  alias Cairn.Observation

  # The smallest step `at_ms` may take. One millisecond binds where whichever
  # clamp is active advances by less than that between two observations: a
  # stalled or rewound pts, since a stream at even 1000 fps advances a full
  # millisecond per frame, and — where `min(…, now_ms)` is the binding one, a
  # pts ahead of the host or a replay faster than real time — a host clock that
  # has not ticked a millisecond since the previous line.
  @floor_ms 1

  @typedoc """
  One camera's clock: the anchor (`anchor_ms` / `anchor_media_ms`, the pair the
  current stretch of tracking time was pinned with) and the previous
  observation's `media_ms` and `at_ms` — `media_ms` is what the rewind test
  reads, `at_ms` what the floor and the continuity re-anchor read. A `nil`
  `anchor_ms` under a non-`nil` `at_ms` is a `reset/1` clock: nothing is pinned,
  but tracking time has a value to continue from.

  `epoch` is `:none` before the first observation, deliberately not `nil`: a v0
  recorded stream before its first epoch mint carries a `nil` epoch for real,
  and must anchor once rather than on every line.
  """
  @type t :: %__MODULE__{
          epoch: String.t() | nil | :none,
          anchor_ms: number() | nil,
          anchor_media_ms: number() | nil,
          media_ms: number() | nil,
          at_ms: number() | nil
        }

  defstruct epoch: :none, anchor_ms: nil, anchor_media_ms: nil, media_ms: nil, at_ms: nil

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Drops the anchor and the previous `media_ms`, keeping `epoch` and `at_ms`.

  For where the plugin process is replaced: its successor continues nobody's
  pts, so the pair the clock was pinned with describes a timeline that no
  longer exists — but tracking time is not the plugin's, and the tracks it
  stamps are the same tracks. The first observation after this re-anchors at
  continuity if it carries the epoch the clock already had, and at `now_ms` if
  it carries a new one, exactly as a rewind and an epoch change do.
  """
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = clock),
    do: %{clock | anchor_ms: nil, anchor_media_ms: nil, media_ms: nil}

  @doc """
  Stamps `observation.at_ms`, returning it with the clock to carry forward.

  `now_ms` is the host's monotonic clock, passed in rather than read here so
  the clamp is testable without sleeping.
  """
  @spec stamp(t(), Observation.t(), number()) :: {Observation.t(), t()}
  def stamp(%__MODULE__{} = clock, %Observation{} = observation, now_ms) do
    clock = anchor(clock, observation, now_ms)

    at_ms =
      clamp(clock.at_ms, clock.anchor_ms + (observation.media_ms - clock.anchor_media_ms), now_ms)

    {%{observation | at_ms: at_ms}, %{clock | media_ms: observation.media_ms, at_ms: at_ms}}
  end

  # Same epoch, and either the pts went backwards or `reset/1` dropped the
  # anchor with the epoch still current: a timeline this clock cannot go on
  # measuring against, under an identity nothing cut. Both re-anchor at
  # continuity, so `media_delta` is zero and this observation is stamped exactly
  # `at_ms + @floor_ms` — see the moduledoc for why this is not `now_ms`. Every
  # observation after it advances at media rate from there, `min(…, now_ms)`
  # catching the clock up to the host rather than dropping it there in one step.
  #
  # A clock in this clause has been stamped at least once, so `at_ms` is set:
  # `epoch` only leaves `:none` by way of the clause below, which stamps.
  defp anchor(
         %__MODULE__{epoch: epoch} = clock,
         %Observation{epoch: epoch} = observation,
         _now_ms
       ) do
    if is_nil(clock.anchor_ms) or observation.media_ms < clock.media_ms do
      %{clock | anchor_ms: clock.at_ms + @floor_ms, anchor_media_ms: observation.media_ms}
    else
      clock
    end
  end

  # A new epoch is a new pts timeline *and* a gap nothing observed, so this one
  # anchors at `now_ms`: `media_delta` is zero, so `at_ms` is `now_ms` — clamped
  # up to `prev + @floor_ms` below, which is what keeps a re-anchor from ever
  # moving the clock backwards.
  defp anchor(clock, observation, now_ms) do
    %{
      clock
      | epoch: observation.epoch,
        anchor_ms: now_ms,
        anchor_media_ms: observation.media_ms
    }
  end

  defp clamp(nil, anchored, now_ms), do: min(anchored, now_ms)
  defp clamp(prev, anchored, now_ms), do: max(prev + @floor_ms, min(anchored, now_ms))
end
