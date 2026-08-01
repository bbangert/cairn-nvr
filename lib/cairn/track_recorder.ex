defmodule Cairn.TrackRecorder do
  @moduledoc """
  The batch writer behind the track index: it buffers finished tracks and their
  timeline moments and hands them to `Cairn.Tracks.insert_batch/1` in batches.

  Every entry point is a cast. `Cairn.DetectionAggregator` is a singleton that
  serves every camera's detections, so it must never wait on SQLite — the
  database is a single file with `busy_timeout: 5_000` and `pool_size: 2`, and
  one contended write would stall detection for every camera at once. The
  aggregator therefore does no `Cairn.Repo` work on the detection path at all;
  it casts here and this process pays the write.

  Two things trigger a flush: `finals` reaching the batch size, and the
  interval timer. A flush with nothing buffered makes no Repo call whatsoever.

  ## Lossy by design

  The buffers live in this process's heap, so a crash or a shutdown loses
  whatever has not been flushed — at most one batch, or one interval's worth of
  finals. That is the same bargain the clip path already makes: an event
  interrupted by a host crash is written `:partial` rather than reconstructed.
  A track row is an audit record of what the system saw, not a receipt, and
  buying the last few seconds of them back would cost the detection path a
  synchronous write.

  For the same reason a refused batch is dropped rather than retried: SQLite
  refuses a write when it is already contended, and a writer that retries is a
  writer camping on a two-connection pool that the clip index also needs.

  There is deliberately **no `terminate/2`**. It is not a durability mechanism:
  it is skipped on a brutal kill and when the VM dies, which are the cases that
  lose data, so a flush there would cover only the orderly stop while reading
  as a guarantee that the crash is covered too. The modules here that do define
  one — `Cairn.FFmpegPort`, `Cairn.PluginPort`, `Cairn.PluginGroupPort` — use
  it to reap an OS process, and `Cairn.FFmpegPort`'s own comment says the same
  thing about how far it reaches. This is a reviewed decision, not an omission.

  `init/1` deliberately does no Repo work, not even an empty flush: in
  `mix test` the application boots before the sandbox is put in `:manual` mode,
  so anything a process writes at boot is committed for real against the test
  database (see
  `.claude/solutions/boot-writes-escape-ecto-sandbox.md`).

  ## Options

    * `:name` — registered name, or `nil` for an anonymous server (tests).
    * `:manual` — suppresses self-scheduling of the flush timer. The token in
      state is still minted, so a test can drive the timer path faithfully.
      The application sets it in the test env, where this singleton's timer
      would otherwise flush one test's tracks through another test's sandbox
      connection.
    * `:flush_interval_ms`, `:flush_batch`, `:max_buffered_finals`,
      `:max_moment_tracks` — the tuning knobs, overridable so a test can reach
      a bound without pushing thousands of casts through it.
  """

  use GenServer

  require Logger

  alias Cairn.{Track, Tracks}

  @flush_interval_ms 5_000
  # One `insert_batch` is one transaction, and `Cairn.Tracks` chunks each
  # table at 400 rows per statement: 200 finals is one statement of tracks and
  # a handful of moments. At a few finished tracks a second — a busy scene
  # across a dozen cameras — the interval timer is what fires first anyway;
  # this is the ceiling on a burst, not the usual trigger.
  @flush_batch 200
  # A track's timeline is a handful of moments: `:appeared` once, then one per
  # stationary flip. A typical track has 2-6. Reaching this many means a box
  # oscillating across the stationary threshold, and the rest of that track's
  # flapping tells a reader nothing the first 32 rows did not.
  @max_moments_per_track 32
  @max_buffered_finals 5_000
  # Moments buffered for tracks that have not ended yet. The steady-state size
  # is the number of live tracks across all cameras (`max_live_tracks`
  # defaults to 128 per camera), so this is a bound on a pathology, not a
  # working set.
  @max_moment_tracks 4_000
  @warn_interval_ms 5_000

  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Buffers a finished track, to be written as a row linked to `event_id`.

  `nil` means the track ended with no event open — the row is still written,
  with a nil `event_id`. That is a statement about the instant the track ended
  and not about whether a clip holds it (`Cairn.Tracks.Track`'s moduledoc has
  the cases); readers that need the latter resolve it by time overlap. Whether
  a no-event track gets a row at all is the caller's gate, not this module's.

  `track` is the runtime `%Cairn.Track{}` final summary — the same struct the
  aggregator broadcasts as `track_ended`.
  """
  @spec record_final(GenServer.server(), Track.t(), String.t() | nil) :: :ok
  def record_final(server \\ __MODULE__, %Track{} = track, event_id) do
    GenServer.cast(server, {:final, track, event_id})
  end

  @doc """
  Buffers one moment on a live track's timeline.

  `at` is the observation's own time, never the wall clock of the call — see
  `Cairn.Tracks.TrackEvent`. Moments are held until the track's final arrives
  and are written in the same transaction as it.
  """
  @spec record_moment(GenServer.server(), String.t(), DateTime.t(), Tracks.TrackEvent.kind(), [
          number()
        ]) :: :ok
  def record_moment(server \\ __MODULE__, object_id, at, kind, bbox)
      when kind in [:appeared, :became_stationary, :started_moving] do
    GenServer.cast(server, {:moment, object_id, at, kind, bbox})
  end

  @doc """
  Drops a track's buffered moments: it ended and will get no row.

  The counterpart of `record_final/3` on the path where the caller's tier gate
  refuses the track — without it, the moments of every gated-out track would
  sit in the buffer until the orphan sweep evicted them.
  """
  @spec discard(GenServer.server(), String.t()) :: :ok
  def discard(server \\ __MODULE__, object_id) do
    GenServer.cast(server, {:discard, object_id})
  end

  # -- server -----------------------------------------------------------------

  @impl true
  def init(opts) do
    state = %{
      manual: Keyword.get(opts, :manual, false),
      flush_interval_ms: Keyword.get(opts, :flush_interval_ms, @flush_interval_ms),
      flush_batch: Keyword.get(opts, :flush_batch, @flush_batch),
      max_buffered_finals: Keyword.get(opts, :max_buffered_finals, @max_buffered_finals),
      max_moment_tracks: Keyword.get(opts, :max_moment_tracks, @max_moment_tracks),
      # newest first: a cast prepends, a flush reverses
      finals: [],
      # object_id => %{list: [moment], count: n, seq: n}, `list` newest first
      moments: %{},
      # bumps on every buffered moment; orders the orphan sweep
      seq: 0,
      flush_token: nil,
      warned_at: %{}
    }

    {:ok, schedule_flush(state)}
  end

  @impl true
  def handle_cast({:final, track, event_id}, state) do
    state = %{state | finals: [{track, event_id} | state.finals]}

    case length(state.finals) do
      count when count >= state.flush_batch -> {:noreply, flush(state)}
      count when count > state.max_buffered_finals -> {:noreply, drop_oldest_final(state)}
      _count -> {:noreply, state}
    end
  end

  def handle_cast({:moment, object_id, at, kind, bbox}, state) do
    {:noreply, put_moment(state, object_id, %{at: at, kind: kind, bbox: bbox})}
  end

  def handle_cast({:discard, object_id}, state) do
    {:noreply, %{state | moments: Map.delete(state.moments, object_id)}}
  end

  # Token discipline, per `.claude/solutions/genserver-timer-cancel-race.md`: a
  # flush message that was already in the mailbox when the token rotated is
  # ignored rather than flushing twice. Nothing here cancels a timer, so the
  # token is also what keeps a forged or replayed `{:flush, ref}` from driving
  # this process.
  @impl true
  def handle_info({:flush, token}, %{flush_token: token} = state) do
    {:noreply, state |> flush() |> schedule_flush()}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule_flush(state) do
    token = make_ref()

    unless state.manual do
      Process.send_after(self(), {:flush, token}, state.flush_interval_ms)
    end

    %{state | flush_token: token}
  end

  # -- buffering --------------------------------------------------------------

  # Backstop, not a routine path: `handle_cast/2` flushes the moment `finals`
  # reaches `flush_batch`, and a flush always empties the buffer (a refused
  # batch is dropped, not retried), so with the default 200 against 5_000 this
  # is unreachable. It is here because "a list grown by a cast" is the shape
  # that eats a node, and nothing but arithmetic between two knobs stops it.
  # Oldest first out: the newest finals are the ones a reader is looking for.
  defp drop_oldest_final(state) do
    dropped = length(state.finals) - state.max_buffered_finals

    warn_once(
      %{state | finals: Enum.take(state.finals, state.max_buffered_finals)},
      :finals_overflow,
      "track recorder: buffered finals over #{state.max_buffered_finals}, " <>
        "dropped #{dropped} oldest"
    )
  end

  defp put_moment(state, object_id, moment) do
    seq = state.seq + 1
    entry = Map.get(state.moments, object_id, %{list: [], count: 0, seq: seq})

    entry =
      if entry.count >= @max_moments_per_track do
        # The earliest moments are kept and the newest refused, which is the
        # opposite of the finals cap: `:appeared` is always a track's first
        # moment and it is the only source of `entry_bbox`, so dropping from
        # the front would silently blank that column on exactly the busiest
        # tracks.
        %{entry | seq: seq}
      else
        %{entry | list: [moment | entry.list], count: entry.count + 1, seq: seq}
      end

    sweep_moments(%{state | seq: seq, moments: Map.put(state.moments, object_id, entry)})
  end

  # Orphan sweep. A moments entry is removed when its track's final arrives, so
  # a track that never gets one — evicted before it ended, or ended by a path
  # the recorder is not wired into — would leak an entry per track, and at
  # `max_unseen_ms` 3000 a busy scene churns tracks by the second.
  #
  # The bound is the map size, enforced here on every buffered moment: the map
  # never holds more than `max_moment_tracks` entries. Overflow drops a quarter
  # of them in one pass, least recently touched first (`seq`), so the O(n log n)
  # sort is paid once per quarter-cap insertions rather than once per
  # insertion. Dropping the least recently touched is what makes the victims
  # the orphans: a live track's entry is touched by every moment it emits, and
  # a track that ended has no entry left to sweep.
  defp sweep_moments(state) do
    if map_size(state.moments) > state.max_moment_tracks do
      keep = state.max_moment_tracks - max(div(state.max_moment_tracks, 4), 1)

      moments =
        state.moments
        |> Enum.sort_by(fn {_id, entry} -> entry.seq end, :desc)
        |> Enum.take(keep)
        |> Map.new()

      warn_once(
        %{state | moments: moments},
        :moment_sweep,
        "track recorder: buffered moments for over #{state.max_moment_tracks} unfinished " <>
          "tracks, swept back to #{keep}"
      )
    else
      state
    end
  end

  # -- flush ------------------------------------------------------------------

  # Nothing buffered, nothing written, and deliberately not even an
  # `insert_batch([])` — which `Cairn.Tracks` answers without opening a
  # transaction today, but that is its choice to revisit, not a property this
  # process should borrow. The timer fires every `flush_interval_ms` on a host
  # where nothing is moving, from a process that holds no sandbox connection
  # in tests and should reach for no real one at 3am.
  defp flush(%{finals: []} = state), do: state

  defp flush(state) do
    finals = Enum.reverse(state.finals)

    entries =
      for {track, event_id} <- finals do
        moments = buffered_moments(state, track.object_id)
        {track_attrs(track, event_id, moments), moments}
      end

    # Only the ids that were paired are forgotten. Moments buffered for a track
    # whose final has not arrived stay — that pairing is the whole shape
    # `Cairn.Tracks.insert_batch/1` asks for.
    ids = for {track, _event_id} <- finals, do: track.object_id
    write(%{state | finals: [], moments: Map.drop(state.moments, ids)}, entries)
  end

  defp buffered_moments(state, object_id) do
    case state.moments do
      %{^object_id => entry} -> Enum.reverse(entry.list)
      _absent -> []
    end
  end

  defp write(state, entries) do
    case Tracks.insert_batch(entries) do
      {:ok, _counts} -> state
      {:error, e} -> dropped(state, entries, Exception.message(e))
    end
  rescue
    # `Cairn.Tracks` turns SQLite's own refusals into `{:error, _}`; an
    # ownership error is the "the database is not answering" case it does not
    # cover, and it is what every Repo call from this process looks like in a
    # test that did not arrange a sandbox for it. Surviving it costs a batch
    # that was already declared droppable — the same judgement
    # `Cairn.DetectionAggregator.indexed_status/1` makes about its own Repo
    # call.
    #
    # Deliberately narrow. A row Ecto refuses to *dump* raises here too
    # (`ArgumentError` out of `Ecto.Type.check_usec!` for a datetime that does
    # not declare microseconds), and that is a bug in what this process built,
    # not a database that is busy: it would raise on every retry and eat the
    # buffer every flush interval, silently, forever. It is prevented where the
    # row is built (`Cairn.Tracks`) rather than swallowed here.
    e in [DBConnection.OwnershipError] -> dropped(state, entries, Exception.message(e))
  catch
    # the pool or the Repo process itself is gone
    :exit, reason -> dropped(state, entries, inspect(reason))
  end

  defp dropped(state, entries, reason) do
    warn_once(
      state,
      :write_failed,
      "track recorder: dropped a batch of #{length(entries)} tracks: #{reason}"
    )
  end

  defp track_attrs(%Track{} = track, event_id, moments) do
    %{
      id: track.object_id,
      camera_id: track.camera_id,
      event_id: event_id,
      label: track.label,
      best_score: track.best_score,
      source: track.source,
      plugin_track_id: track.plugin_track_id,
      epoch: track.epoch,
      started_at: track.started_at,
      # The track's own last observation time, not the wall clock of this
      # write, which is up to a flush interval later.
      ended_at: track.last_seen_at,
      end_reason: track.end_reason,
      stationary_since: track.stationary_since,
      stationary_ms: track.stationary_ms,
      # Nil when the `:appeared` moment is absent: the track started before
      # this process did, or its whole moment buffer was swept as an orphan
      # before the final arrived. Never the per-track cap — that keeps the
      # earliest moments, and `:appeared` is always first.
      entry_bbox: entry_bbox(moments),
      exit_bbox: track.bbox,
      # Schema-reserved and left nil here: `%Cairn.Track{}` carries
      # `best_score` but not the box that scored it.
      best_bbox: nil
    }
  end

  defp entry_bbox(moments) do
    case Enum.find(moments, &(&1.kind == :appeared)) do
      %{bbox: bbox} -> bbox
      nil -> nil
    end
  end

  # Every warning here is driven by a condition that repeats at the rate of the
  # thing that caused it — a locked database, a scene churning tracks — so
  # unrate-limited they are a log flood. Same shape as `Cairn.Tracker`'s.
  defp warn_once(state, class, message) do
    now = System.monotonic_time(:millisecond)
    last = Map.get(state.warned_at, class)

    if is_nil(last) or now - last >= @warn_interval_ms do
      Logger.warning(message)
      %{state | warned_at: Map.put(state.warned_at, class, now)}
    else
      state
    end
  end
end
