defmodule CairnWeb.TrackMoments do
  @moduledoc """
  A track's timeline as the design lists it, shared by `CairnWeb.TracksLive`
  (row expansion) and `CairnWeb.EventLive` (tracked-objects panel).

  `rows/3` answers *what happened, and when*. It deliberately stops short of
  *how to print the when*, because the two callers disagree: a track row on the
  browse page measures offsets from the track's own start, while the event
  panel measures them from the clip's start — and prints an absolute time
  instead for a moment that belongs to some other clip. So every row carries
  `:at`, the moment's own instant, and the caller formats it. `fmt_clock/2` is
  here for the callers that want the offset form.

  The collapsing rule is the reason this module exists rather than two copies of
  it: a `became_stationary` immediately followed by `started_moving` is one row,
  and getting that subtly different in two places would show up as two
  different stories about the same track.
  """

  alias CairnWeb.EventsLive

  @typedoc """
  One presented moment. `:suffix` and `:title` are `nil` when the row has
  neither; `:title` is the tooltip gloss on an end reason.
  """
  @type row :: %{
          icon: String.t(),
          text: String.t(),
          at: DateTime.t(),
          suffix: String.t() | nil,
          title: String.t() | nil
        }

  # Plain-language glosses for `Cairn.Tracks.Track`'s six end reasons, shown as
  # the tooltip on the "ended" moment. Every value the schema's `Ecto.Enum`
  # accepts needs an entry here — a new reason there without one here renders a
  # bare atom name with no tooltip.
  @reason_gloss %{
    unseen: "Left view and wasn't seen again",
    plugin_ended: "The detection plugin closed the track",
    stream_reset: "The camera stream restarted",
    evicted: "Dropped to cap memory use",
    detection_disabled: "Detection was turned off",
    host_restart: "Cairn restarted"
  }

  @doc """
  A track's moments as the design lists them: `appeared`, collapsed stationary
  runs, bare `started_moving`, then a synthetic `ended` row carrying the end
  reason (the tracks table holds that on the track, not as a moment of its own).

  `moments` must be oldest first — the order `Cairn.Tracks.moments/1` and
  `moments_for/1` both return. `now` dates an ongoing stationary run on a track
  that has not ended.
  """
  @spec rows(map(), [map()], DateTime.t()) :: [row()]
  def rows(track, moments, now) do
    collapse(moments, track, now) ++ ended_row(track)
  end

  @doc """
  An offset as m:ss, or h:mm:ss once it passes an hour. A negative offset
  clamps to zero rather than printing something like `-1:-30`.

  Nothing reaches that clamp today: `CairnWeb.TracksLive` measures from the
  track's own start, and `CairnWeb.EventLive` formats a moment against the clip
  only on the branch where `Cairn.Tracks.moment_clips/3` already found that clip
  *contains* it. It is the function's contract for its callers, not a case with
  a live path to it — `test/cairn_web/live/track_moments_test.exs` is what keeps
  it true.
  """
  @spec fmt_clock(DateTime.t(), DateTime.t()) :: String.t()
  def fmt_clock(from, at), do: at |> DateTime.diff(from) |> max(0) |> fmt_clock()

  @doc "The same, from a whole number of seconds."
  @spec fmt_clock(integer()) :: String.t()
  def fmt_clock(seconds) do
    total = max(seconds, 0)
    m = div(rem(total, 3600), 60)
    s = rem(total, 60)

    case div(total, 3600) do
      0 -> "#{m}:#{pad(s)}"
      h -> "#{h}:#{pad(m)}:#{pad(s)}"
    end
  end

  @doc "The plain-language gloss for an end reason, or `nil` for an unknown one."
  @spec reason_gloss(atom()) :: String.t() | nil
  def reason_gloss(reason), do: Map.get(@reason_gloss, reason)

  # A `became_stationary` immediately followed by `started_moving` is one row —
  # "stationary · for 2h 14m" — and the run's end is implied by the timestamp of
  # whatever comes next, so the `started_moving` that closed it is consumed. A
  # `started_moving` that closes no run renders on its own.
  defp collapse([], _track, _now), do: []

  defp collapse(
         [%{kind: :became_stationary} = m, %{kind: :started_moving} = mv | rest],
         track,
         now
       ) do
    [stationary_row(m.at, mv.at) | collapse(rest, track, now)]
  end

  defp collapse([%{kind: :became_stationary} = m | rest], track, now) do
    # An unclosed run: still going for a live track, otherwise it ran until the
    # track itself ended.
    row =
      if is_nil(track.ended_at) do
        %{
          icon: "motion_photos_paused",
          at: m.at,
          text: "stationary",
          suffix: "· ongoing — #{span(m.at, now)} so far",
          title: nil
        }
      else
        stationary_row(m.at, track.ended_at)
      end

    [row | collapse(rest, track, now)]
  end

  defp collapse([m | rest], track, now) do
    [
      %{
        icon: kind_icon(m.kind),
        at: m.at,
        text: kind_text(m.kind),
        suffix: nil,
        title: nil
      }
      | collapse(rest, track, now)
    ]
  end

  defp stationary_row(from, to) do
    %{
      icon: "motion_photos_paused",
      at: from,
      text: "stationary",
      suffix: "· for #{span(from, to)}",
      title: nil
    }
  end

  defp ended_row(%{ended_at: nil}), do: []

  defp ended_row(track) do
    [
      %{
        icon: "flag",
        at: track.ended_at,
        text: "ended",
        suffix: if(track.end_reason, do: "· #{track.end_reason}"),
        title: reason_gloss(track.end_reason)
      }
    ]
  end

  defp kind_icon(:appeared), do: "trip_origin"
  defp kind_icon(:started_moving), do: "north_east"
  defp kind_icon(:became_stationary), do: "motion_photos_paused"

  defp kind_text(:appeared), do: "appeared"
  defp kind_text(:started_moving), do: "started moving"
  defp kind_text(:became_stationary), do: "stationary"

  defp span(from, to), do: EventsLive.fmt_duration(%{started_at: from, ended_at: to})

  defp pad(n), do: String.pad_leading(Integer.to_string(n), 2, "0")
end
