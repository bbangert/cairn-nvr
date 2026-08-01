defmodule Cairn.TrackRecorder do
  @moduledoc """
  The batch writer behind the track index: it buffers the tracks that earn a
  row, together with their timeline moments, and hands them to
  `Cairn.Tracks.insert_batch/1` in batches.

  A row is opened while its track is still running and closed when the track
  ends, so a track has three kinds of write here — `record_open/3` once,
  `record_update/3` on the aggregator's throttle, `record_final/3` to close —
  and all three are the same upsert on the same id. This process owns the one
  piece of state that decides between them: which ids have a row. The caller
  does not know and is not asked to; an update for an id with no row is
  ignored, and a re-sent open is the update it looks like.

  Every entry point is a cast. `Cairn.DetectionAggregator` is a singleton that
  serves every camera's detections, so it must never wait on SQLite — the
  database is a single file with `busy_timeout: 5_000` and `pool_size: 2`, and
  one contended write would stall detection for every camera at once. The
  aggregator therefore does no `Cairn.Repo` work on the detection path at all;
  it casts here and this process pays the write.

  Two things trigger a flush: the number of tracks with a queued write reaching
  the batch size, and the interval timer. A flush with nothing queued makes no
  Repo call whatsoever.

  ## Lossy by design

  The buffers live in this process's heap, so a crash or a shutdown loses
  whatever has not been flushed — at most one batch, or one interval's worth of
  writes. That is the same bargain the clip path already makes: an event
  interrupted by a host crash is written `:partial` rather than reconstructed.
  A track row is an audit record of what the system saw, not a receipt, and
  buying the last few seconds of them back would cost the detection path a
  synchronous write.

  Losing a write is not symmetric, though, and live rows are why. A lost open
  or update costs the tail of a row that a later write restores. A lost
  **close** leaves a row that says the object is still in frame, and nothing
  running ever revisits it: only `Cairn.Tracks.close_live/0`, at the next boot,
  does. So an interrupted host leaves live rows behind on purpose, and they are
  closed on the way back up rather than written twice on the way down.

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
    * `:flush_interval_ms`, `:flush_batch`, `:max_tracks` — the tuning knobs,
      overridable so a test can reach a bound without pushing thousands of
      casts through it.
  """

  use GenServer

  require Logger

  alias Cairn.{Track, Tracks}

  @flush_interval_ms 5_000
  # One `insert_batch` is one transaction, and `Cairn.Tracks` chunks each
  # table at 400 rows per statement: 200 tracks is one statement of tracks and
  # a handful of moments. Writes are per track and not per cast — a track
  # updated ten times between two flushes is one row either way — so on a busy
  # scene across a dozen cameras this is reached by the number of objects in
  # frame, not by the frame rate. The interval timer is still what fires first
  # on anything quieter.
  @flush_batch 200
  # A track's timeline is a handful of moments: `:appeared` once, then one per
  # stationary flip. A typical track has 2-6. Reaching this many means a box
  # oscillating across the stationary threshold, and the rest of that track's
  # flapping tells a reader nothing the first 32 rows did not. Counted over the
  # track's whole life, not per batch: the count survives the flush that writes
  # them.
  @max_moments_per_track 32
  # Tracks held in memory at once — one entry per track this process has heard
  # of and not yet closed. The steady-state size is the number of live tracks
  # across all cameras (`max_live_tracks` defaults to 128 per camera), so this
  # is a bound on a pathology, not a working set.
  @max_tracks 4_000
  @warn_interval_ms 5_000

  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Opens a row for a track that is still running, linked to `event_id`.

  The caller's gate, not this module's: a track only reaches here once it has
  earned a row (`Cairn.DetectionAggregator`'s `track:` tier), and one that
  never earns one is never mentioned. Sending it twice is harmless — the second
  is treated as `record_update/3`, so nothing duplicates and nothing resets.

  The row is written with a nil `ended_at`, which is what "live" means in the
  `tracks` table, and it carries whatever moments were buffered for the track
  before it qualified.

  `track` is the runtime `%Cairn.Track{}` summary — the same struct the
  aggregator broadcasts as `track_started`.
  """
  @spec record_open(GenServer.server(), Track.t(), String.t() | nil) :: :ok
  def record_open(server \\ __MODULE__, %Track{} = track, event_id) do
    GenServer.cast(server, {:open, track, event_id})
  end

  @doc """
  Refreshes a live track's row from a newer summary.

  Ignored for a track with no row here — one that never qualified, or one this
  process has forgotten (it restarted, or the track was swept). Ignoring is the
  conservative half: a row that stops being refreshed goes stale until its
  close, where creating one would invent a row for a track the caller's gate
  refused.

  Called on the aggregator's update throttle rather than per batch: the row
  follows the same rhythm as the `track_updated` broadcast.
  """
  @spec record_update(GenServer.server(), Track.t(), String.t() | nil) :: :ok
  def record_update(server \\ __MODULE__, %Track{} = track, event_id) do
    GenServer.cast(server, {:update, track, event_id})
  end

  @doc """
  Closes a finished track's row, writing it first if it has none.

  `nil` means the track ended with no event open — the row is still written,
  with a nil `event_id`. That is a statement about the instant the track ended
  and not about whether a clip holds it (`Cairn.Tracks.Track`'s moduledoc has
  the cases); readers that need the latter resolve it by time overlap.

  Unlike `record_update/3` this always writes, because it is the one write that
  must not be conditional on what this process remembers: a track whose row was
  opened before a restart here, or whose open never happened at all (checkpoint
  restore knows nothing of one), still has to end up closed.

  `track` is the runtime `%Cairn.Track{}` final summary — the same struct the
  aggregator broadcasts as `track_ended`.
  """
  @spec record_final(GenServer.server(), Track.t(), String.t() | nil) :: :ok
  def record_final(server \\ __MODULE__, %Track{} = track, event_id) do
    GenServer.cast(server, {:final, track, event_id})
  end

  @doc """
  Buffers one moment on a track's timeline.

  `at` is the observation's own time, never the wall clock of the call — see
  `Cairn.Tracks.TrackEvent`. A moment for a track with a row is written with the
  next batch; one for a track without is held until the track earns a row, and
  dropped if it never does.
  """
  @spec record_moment(GenServer.server(), String.t(), DateTime.t(), Tracks.TrackEvent.kind(), [
          number()
        ]) :: :ok
  def record_moment(server \\ __MODULE__, object_id, at, kind, bbox)
      when kind in [:appeared, :became_stationary, :started_moving] do
    GenServer.cast(server, {:moment, object_id, at, kind, bbox})
  end

  @doc """
  Drops everything held for a track: it ended and will get no row.

  The counterpart of `record_final/3` on the path where the caller's tier gate
  refuses the track — without it, the moments of every gated-out track would
  sit in the buffer until the orphan sweep evicted them.

  Only for a track that never earned a row. The caller decides that, and one
  that sends this for a track it did open leaves the row live until
  `Cairn.Tracks.close_live/0` collects it at the next boot; that is why
  `Cairn.DetectionAggregator` tracks what it has opened rather than re-deciding
  at the end.
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
      max_tracks: Keyword.get(opts, :max_tracks, @max_tracks),
      # object_id => entry(); see `new_entry/1`
      tracks: %{},
      # ids with a write queued for the next flush. Usually ids of `tracks`;
      # the sweep can leave one whose entry is gone (see `sweep/1`).
      dirty: MapSet.new(),
      # bumps on every cast that touches a track; orders the sweep
      seq: 0,
      flush_token: nil,
      warned_at: %{}
    }

    {:ok, schedule_flush(state)}
  end

  @impl true
  def handle_cast({:open, track, event_id}, state) do
    {:noreply, state |> write_row(track, event_id, false) |> maybe_flush()}
  end

  # The one cast that is conditional on what this process remembers: a track
  # with no row here has nothing to refresh, and inventing one would write a row
  # the caller's gate never asked for.
  def handle_cast({:update, track, event_id}, state) do
    if rowed?(state, track.object_id) do
      {:noreply, state |> write_row(track, event_id, false) |> maybe_flush()}
    else
      {:noreply, state}
    end
  end

  def handle_cast({:final, track, event_id}, state) do
    {:noreply, state |> write_row(track, event_id, true) |> maybe_flush()}
  end

  def handle_cast({:moment, object_id, at, kind, bbox}, state) do
    {:noreply, state |> put_moment(object_id, %{at: at, kind: kind, bbox: bbox}) |> maybe_flush()}
  end

  def handle_cast({:discard, object_id}, state) do
    {:noreply, forget(state, object_id)}
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

  defp new_entry(seq) do
    %{
      # the row to write on the next flush, nil until the track earns one. Also
      # the answer to "does this track have a row?": every path that sets it
      # writes the row, and nothing ever sets it back — an entry is dropped
      # whole (a flushed close, a discard, the sweep) rather than emptied.
      attrs: nil,
      # newest first; a flush reverses them and forgets them
      moments: [],
      # over the track's whole life, for the per-track cap
      count: 0,
      # the `:appeared` box, kept out of `moments` so it survives both the flush
      # that writes that moment and the per-track cap
      entry_bbox: nil,
      # this track's row is closed and the entry goes with the flush
      closing?: false,
      seq: seq
    }
  end

  # Opens or refreshes a track's row. `closing?` is the difference between the
  # three casts that get here: an open and an update write a live row (nil
  # `ended_at`), a final writes the closed one and takes the entry with it.
  defp write_row(state, track, event_id, closing?) do
    seq = state.seq + 1
    entry = Map.get(state.tracks, track.object_id, new_entry(seq))
    entry = %{entry | attrs: track_attrs(track, event_id, entry, closing?), closing?: closing?}

    state
    |> put_entry(track.object_id, %{entry | seq: seq}, seq)
    |> dirty(track.object_id)
  end

  defp put_moment(state, object_id, moment) do
    seq = state.seq + 1
    entry = Map.get(state.tracks, object_id, new_entry(seq))

    entry =
      if entry.count >= @max_moments_per_track do
        # The earliest moments are kept and the newest refused, the opposite of
        # the sweep below, which keeps the most recently touched: a timeline's
        # first rows are what a reader reconstructs the track from, and a track
        # that has flipped stationary 32 times has told that story already.
        entry
      else
        %{entry | moments: [moment | entry.moments], count: entry.count + 1}
      end

    state
    |> put_entry(object_id, %{entry | seq: seq, entry_bbox: entry_bbox(entry, moment)}, seq)
    |> dirty_if_rowed(object_id)
  end

  # The `:appeared` box, taken once. It is the row's `entry_bbox` and the only
  # source of it, so it is held apart from the moment list rather than read back
  # out of it: the list is emptied by every flush.
  defp entry_bbox(%{entry_bbox: nil}, %{kind: :appeared, bbox: bbox}), do: bbox
  defp entry_bbox(%{entry_bbox: bbox}, _moment), do: bbox

  defp put_entry(state, object_id, entry, seq) do
    sweep(%{state | seq: seq, tracks: Map.put(state.tracks, object_id, entry)})
  end

  defp dirty(state, object_id), do: %{state | dirty: MapSet.put(state.dirty, object_id)}

  # A moment for a track with no row cannot be written — `track_events.track_id`
  # is a real foreign key — so it queues nothing and waits for the open that
  # will carry it.
  defp dirty_if_rowed(state, object_id) do
    if rowed?(state, object_id), do: dirty(state, object_id), else: state
  end

  # A row exists, or a write that creates it is already queued. `attrs` is set
  # by exactly the three casts that write a row and cleared by nothing.
  defp rowed?(state, object_id) do
    case state.tracks do
      %{^object_id => %{attrs: attrs}} -> attrs != nil
      _absent -> false
    end
  end

  defp forget(state, object_id) do
    %{
      state
      | tracks: Map.delete(state.tracks, object_id),
        dirty: MapSet.delete(state.dirty, object_id)
    }
  end

  # Orphan sweep. An entry is removed when its track's close is written, so a
  # track that never gets one — evicted before it ended, or ended by a path the
  # recorder is not wired into — would leak an entry per track, and at
  # `max_unseen_ms` 3000 a busy scene churns tracks by the second.
  #
  # The bound is the map size, enforced here on every cast that touches a track:
  # the map never holds more than `max_tracks` entries. Overflow drops a quarter
  # of them in one pass, least recently touched first (`seq`), so the O(n log n)
  # sort is paid once per quarter-cap insertions rather than once per insertion.
  # Dropping the least recently touched is what makes the victims the orphans: a
  # live track's entry is touched by every update it draws, and a track that
  # ended has no entry left to sweep.
  #
  # A swept track that is still alive is not lost, only forgotten: its updates
  # are ignored from here on, and its close writes and closes its row whatever
  # this process remembers.
  #
  # `dirty` is left holding ids this may have just dropped, and deliberately —
  # it is emptied by the next flush either way, and that flush skips an id with
  # no entry. Anything queued for a swept track goes with it, which is the same
  # bargain as everything else here.
  defp sweep(state) do
    if map_size(state.tracks) > state.max_tracks do
      keep = state.max_tracks - max(div(state.max_tracks, 4), 1)

      tracks =
        state.tracks
        |> Enum.sort_by(fn {_id, entry} -> entry.seq end, :desc)
        |> Enum.take(keep)
        |> Map.new()

      warn_once(
        %{state | tracks: tracks},
        :sweep,
        "track recorder: buffering over #{state.max_tracks} unfinished tracks, " <>
          "swept back to #{keep}"
      )
    else
      state
    end
  end

  # -- flush ------------------------------------------------------------------

  defp maybe_flush(state) do
    if MapSet.size(state.dirty) >= state.flush_batch, do: flush(state), else: state
  end

  # Nothing queued, nothing written, and deliberately not even an
  # `insert_batch([])` — which `Cairn.Tracks` answers without opening a
  # transaction today, but that is its choice to revisit, not a property this
  # process should borrow. The timer fires every `flush_interval_ms` on a host
  # where nothing is moving, from a process that holds no sandbox connection
  # in tests and should reach for no real one at 3am.
  defp flush(state) do
    if MapSet.size(state.dirty) == 0 do
      state
    else
      dirty = MapSet.to_list(state.dirty)

      # `entry =` in a generator filter: an id the sweep dropped since it was
      # queued has no entry and is skipped.
      entries =
        for id <- dirty, entry = Map.get(state.tracks, id) do
          {entry.attrs, Enum.reverse(entry.moments)}
        end

      state = %{state | dirty: MapSet.new(), tracks: Enum.reduce(dirty, state.tracks, &settle/2)}
      write(state, entries)
    end
  end

  # What survives a write: nothing, for a track whose close just went out, and
  # for the rest the entry minus the moments now in the database. `attrs` stays
  # — it is what pairs a later moment with its row, and rewriting an unchanged
  # row costs one upsert that changes no column but `updated_at`.
  defp settle(id, tracks) do
    case tracks do
      %{^id => %{closing?: true}} -> Map.delete(tracks, id)
      %{^id => entry} -> Map.put(tracks, id, %{entry | moments: []})
      _swept -> tracks
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
    # A row Ecto refuses to *dump* also raises out of the insert
    # (`Ecto.ChangeError` for a value that does not match its column type,
    # `ArgumentError` out of `Ecto.Type.check_usec!` for a datetime that does
    # not declare microseconds). That is a bug in what this process built, and
    # the primary defense is prevention where the row is built
    # (`Cairn.Tracks.track_row/2` normalizes datetimes and float
    # milliseconds). But prevention has now been beaten twice by value shapes
    # the fixtures were uniform in — wire-precision datetimes, then the media
    # clock's float `stationary_ms` — and each time the narrow rescue turned
    # one bad value into a crash-loop that silently ate every buffered write,
    # closes included, forever. So dump refusals are dropped-and-logged like
    # an unanswered database: one loud lost batch, a process that keeps
    # closing rows, and boot reconciliation covering whatever the lost batch
    # held.
    e in [DBConnection.OwnershipError, Ecto.ChangeError, ArgumentError] ->
      dropped(state, entries, Exception.message(e))
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

  # The row as `Cairn.Tracks.insert_batch/1` takes it. Built the same way for
  # all three writes, because they are the same upsert: a live row is one whose
  # `ended_at` and `end_reason` are still nil.
  defp track_attrs(%Track{} = track, event_id, entry, closing?) do
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
      ended_at: if(closing?, do: track.last_seen_at),
      end_reason: if(closing?, do: track.end_reason),
      stationary_since: track.stationary_since,
      stationary_ms: track.stationary_ms,
      # Nil when no `:appeared` moment was ever buffered here: the track
      # started before this process did, or its entry was swept. Never the
      # per-track cap, and never a flush — it is held outside the moment list
      # for exactly that reason. `Cairn.Tracks` does not replace this column on
      # a later write, so a nil here cannot blank a box already stored.
      entry_bbox: entry.entry_bbox,
      # The latest box, which on the closing write is where the track left.
      exit_bbox: track.bbox,
      # Schema-reserved and left nil here: `%Cairn.Track{}` carries
      # `best_score` but not the box that scored it.
      best_bbox: nil
    }
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
