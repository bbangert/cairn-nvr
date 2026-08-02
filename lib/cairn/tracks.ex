defmodule Cairn.Tracks do
  @moduledoc """
  Track index context — the only module that touches the `tracks` and
  `track_events` tables. The batch writer, the retention sweep and every reader
  go through here.

  The tables exist for one question the event index cannot answer: *what did
  the system see and not record?* Every track gets a row whether or not a clip
  was open, so the rows themselves are the answer; which of them a clip holds
  is decided by time overlap, not by `tracks.event_id` — see
  `first_overlapping_event_ids/2` and `Cairn.Tracks.Track`'s moduledoc for why
  that column cannot carry it.

  A row appears while its track is still running and is rewritten as the track
  changes, so `insert_batch/1` upserts rather than inserts (`ended_at IS NULL`
  is the live state). `close_live/0` is the other half of that: nothing but a
  writer's own close ends a row, so a host that died mid-track leaves one live
  forever until boot reconciliation closes it.

  `Cairn.Tracks.Track` here is the row, not `Cairn.Track` the runtime broadcast
  struct — the same distinction as `Cairn.Events.Event` and `Cairn.Event`.

  Writes stay inside the two tables named above. Reads do not: relating a track
  to a clip is a question about time and the `events` table, asked three ways —
  `first_overlapping_event_ids/2` (which clip does this track belong to?),
  `overlapping_event/3` (which tracks belong to this clip?) and
  `moment_clips/3` (which clip contains this instant?). All three select from
  `Cairn.Events.Event` here rather than making the callers stitch two contexts
  together per page.
  """

  import Ecto.Query

  alias Cairn.Events.Event
  alias Cairn.Repo
  alias Cairn.Tracks.Track
  alias Cairn.Tracks.TrackEvent

  @type track_attrs :: %{
          required(:id) => String.t(),
          required(:camera_id) => String.t(),
          required(:started_at) => DateTime.t(),
          optional(atom()) => term()
        }
  @type moment_attrs :: %{
          required(:at) => DateTime.t(),
          required(:kind) => TrackEvent.kind(),
          optional(:bbox) => [number()] | nil
        }
  @type entry :: {track_attrs(), [moment_attrs()]}
  @type counts :: %{tracks: non_neg_integer(), moments: non_neg_integer()}

  @type list_opts :: [
          camera: String.t() | nil,
          label: String.t() | nil,
          from: DateTime.t() | nil,
          to: DateTime.t() | nil,
          zone: String.t() | nil,
          min_stationary_ms: non_neg_integer() | nil,
          page: pos_integer(),
          page_size: pos_integer()
        ]

  # The bundled SQLite is 3.53.3, whose SQLITE_MAX_VARIABLE_NUMBER is 32766 —
  # one bind variable per cell, and `insert_all` is a single statement that
  # ecto_sqlite3 does not chunk for us. That caps a `tracks` insert (19 columns)
  # at 1724 rows and a `track_events` insert (4 columns) at 8191. At 400 the
  # margin is 4.3x on tracks and 20x on moments; tracks is the one to watch,
  # since every column added to that table shrinks its margin. 400 also keeps
  # the generated statement text small enough to stay cheap to parse.
  @chunk_size 400

  @spec get(String.t()) :: Track.t() | nil
  def get(id), do: Repo.get(Track, id)

  # The columns a later offer of the same id may overwrite. Everything left out
  # is either the track's identity (`camera_id`, `started_at`, `source`,
  # `plugin_track_id` — none of which change over a track's life), the instant
  # the row first appeared (`inserted_at`), or `entry_bbox`, which comes from
  # the `:appeared` moment and is therefore known only to the writer that
  # opened the row: a later offer carries nil there and must not blank it.
  #
  # `epoch` is in the list and is *not* identity: a host track that survives a
  # stream reset by being adopted out of suspension keeps its id and moves to
  # the new epoch (`Cairn.Tracker`), so the column means the stream this track
  # was last observed under, which is the one a reader wanting its media should
  # look in.
  #
  # `updated_at` is in the list and load-bearing beyond bookkeeping —
  # `close_live/0` reads it as the instant a row was last known live.
  @replace_on_conflict [
    :event_id,
    :label,
    :best_score,
    :epoch,
    :ended_at,
    :end_reason,
    :stationary_since,
    :stationary_ms,
    :exit_bbox,
    :best_bbox,
    :zones,
    :updated_at
  ]

  @doc """
  Writes tracks and their timeline moments in one transaction.

  Takes each track paired with its own moments — a list of
  `{track_attrs, [moment_attrs]}`. `track_attrs` is a map with atom keys;
  `:id`, `:camera_id` and `:started_at` are required and everything else is
  optional. Each moment carries `:at`, `:kind` and optionally `:bbox`.

  Moments do **not** carry `:track_id`: it comes from the track they are paired
  with. That is the point of the shape. `track_events.track_id` is a real
  foreign key, so a moment whose parent is not in the same batch would fail the
  insert and take the whole transaction with it — pairing makes that row
  unrepresentable. It also suits a caller that holds a track's row and its
  timeline together: it passes the pair, and moments buffered for a track whose
  row does not exist yet are simply never passed here.

  Every `DateTime` passed here is padded to microsecond precision on the way
  in, whatever precision it declares — a caller holding wire time does not have
  to pad it, and one that already did changes nothing. The reason is with the
  row builders: these columns are `:utc_datetime_usec`, `insert_all` dumps
  without casting, and that dump *raises* on any other precision.

  Tracks **upsert** on `:id`, replacing the columns listed in
  `@replace_on_conflict` and keeping the rest. Offering an id repeatedly is the
  normal path, not a race: `Cairn.TrackRecorder` opens a row while the track is
  still running, offers the same id again on every update, and once more to
  close it. Last write wins, which also makes the genuine races harmless — a
  checkpoint restore finalizes tracks as `:host_restart` that a crash-time flush
  may already have written, and a boot-time `close_live/0` may have closed
  before either.

  Moments have no such guard: offer one twice and it is on the timeline twice —
  harmless to read, and preferable to dropping the audit row. The recorder never
  does, because it forgets a track's moments once they are written, so a
  re-offered track carries none.

  Returns `{:ok, %{tracks: n, moments: n}}`, or `{:error, exception}` if SQLite
  refuses the write (busy, locked, constraint) — a value rather than an exit,
  because the caller is expected to be lossy and drop the batch rather than
  retry against a database that is already contended. A refused batch leaves
  nothing behind: both inserts share one transaction.

  `tracks` counts rows **written**, an update the same as an insert: SQLite
  reports a `DO UPDATE` row as changed and nothing here can tell the two apart.
  """
  @spec insert_batch([entry()]) :: {:ok, counts()} | {:error, Exception.t()}
  def insert_batch([]), do: {:ok, %{tracks: 0, moments: 0}}

  def insert_batch(entries) when is_list(entries) do
    now = DateTime.utc_now()
    track_rows = Enum.map(entries, fn {track, _moments} -> track_row(track, now) end)

    moment_rows =
      Enum.flat_map(entries, fn {track, moments} ->
        Enum.map(moments, &moment_row(&1, Map.fetch!(track, :id)))
      end)

    Repo.transaction(fn ->
      %{
        tracks:
          insert_chunked(Track, track_rows,
            on_conflict: {:replace, @replace_on_conflict},
            conflict_target: :id
          ),
        moments: insert_chunked(TrackEvent, moment_rows, [])
      }
    end)
  rescue
    e in [Exqlite.Error, DBConnection.ConnectionError] -> {:error, e}
  end

  @doc "A track's timeline, oldest moment first."
  @spec moments(String.t()) :: [TrackEvent.t()]
  def moments(track_id) do
    TrackEvent
    |> where([m], m.track_id == ^track_id)
    |> order_by([m], asc: m.at)
    |> Repo.all()
  end

  @doc """
  The moments of many tracks at once, as `%{track_id => [TrackEvent.t()]}`.

  One query for a whole page of rows, so a track list never fans out into a
  `moments/1` per row. `Enum.group_by/2` keeps the enumeration order inside each
  group, so every list comes back oldest moment first, exactly like `moments/1`.

  A track with no moments is simply absent from the map — callers read it with
  `Map.get(map, id, [])`, which is also what an unknown id answers.
  """
  @spec moments_for([String.t()]) :: %{String.t() => [TrackEvent.t()]}
  def moments_for([]), do: %{}

  def moments_for(track_ids) when is_list(track_ids) do
    TrackEvent
    |> where([m], m.track_id in ^track_ids)
    |> order_by([m], asc: m.at)
    |> Repo.all()
    |> Enum.group_by(& &1.track_id)
  end

  @doc """
  Maps each track to the first surviving clip it overlaps: `%{track_id =>
  event_id}`. Tracks with no overlapping event row are absent from the map.

  Linking is by **time overlap on the same camera**, not by `tracks.event_id`:
  that column names the event that was open when the track *ended*, so a track
  spanning two clips, or one that ended between them, points at the wrong clip
  or at none. Overlap is the honest question — "was a camera recording while
  this object was in frame?"

  The rule, with a track's window `[started_at, ended_at || now]` and an event's
  `[started_at, ended_at || still recording]`:

      event.started_at <= track_end AND (event.ended_at IS NULL OR event.ended_at >= track.started_at)

  A NULL `events.ended_at` means the clip is still being written, so its window
  has no end yet and only the first half of the test can fail. Boundaries are
  inclusive: an event that starts at the exact instant a track ends overlaps it.

  Two passes, one query total, whatever the page size: the events that could
  possibly overlap *any* track on the page are fetched in one go (bounded by the
  page's cameras and its outermost instants), then each track picks the earliest
  of them that overlaps it. The `events` table is small next to a page of tracks
  — a clip is minutes of many tracks — so the per-track match runs in Elixir
  rather than as a lateral subquery SQLite would have to plan per row.
  """
  @spec first_overlapping_event_ids([Track.t()], DateTime.t()) :: %{String.t() => String.t()}
  def first_overlapping_event_ids(tracks, now \\ DateTime.utc_now())

  def first_overlapping_event_ids([], _now), do: %{}

  def first_overlapping_event_ids(tracks, now) when is_list(tracks) do
    cameras = tracks |> Enum.map(& &1.camera_id) |> Enum.uniq()
    window_start = tracks |> Enum.map(& &1.started_at) |> Enum.min(DateTime)
    window_end = tracks |> Enum.map(&track_end(&1, now)) |> Enum.max(DateTime)

    by_camera =
      Event
      |> where([e], e.camera_id in ^cameras)
      |> where([e], e.started_at <= ^window_end)
      |> where([e], is_nil(e.ended_at) or e.ended_at >= ^window_start)
      |> order_by([e], asc: e.started_at)
      |> select([e], %{
        id: e.id,
        camera_id: e.camera_id,
        started_at: e.started_at,
        ended_at: e.ended_at
      })
      |> Repo.all()
      |> Enum.group_by(& &1.camera_id)

    Enum.reduce(tracks, %{}, fn track, acc ->
      track_end = track_end(track, now)

      by_camera
      |> Map.get(track.camera_id, [])
      |> Enum.find(&overlaps?(&1, track.started_at, track_end))
      |> case do
        nil -> acc
        event -> Map.put(acc, track.id, event.id)
      end
    end)
  end

  defp track_end(%Track{ended_at: nil}, now), do: now
  defp track_end(%Track{ended_at: ended_at}, _now), do: ended_at

  defp overlaps?(event, track_start, track_end) do
    DateTime.compare(event.started_at, track_end) != :gt and
      (is_nil(event.ended_at) or DateTime.compare(event.ended_at, track_start) != :lt)
  end

  @doc """
  Every track whose lifetime overlaps one clip's window, oldest first.

  The mirror of `first_overlapping_event_ids/2` — same relation, asked from the
  other side — and the same reason for existing: `tracks.event_id` names the
  event that was open when a track *ended*, so a track spanning two clips, or
  one that ended between them, is missing from or wrong in any read of that
  column. This answers the question the panel actually asks: *what was in frame
  while this clip was being written?*

  With a track's window `[started_at, ended_at || now]` and the event's
  `[started_at, ended_at || now]`:

      track.started_at <= event_end AND (track.ended_at IS NULL OR track.ended_at >= event.started_at)

  A NULL `ended_at` on either side means "still going", so that side's window
  has no end yet. Boundaries are inclusive, exactly as in
  `first_overlapping_event_ids/2`: a track that starts at the instant a clip
  ends overlaps it.

  Unbounded unless `:limit` says otherwise. A clip of ordinary length overlaps
  a handful of tracks and the panel wants all of them, but a day-long event on
  a busy camera was in frame of thousands, and `CairnWeb.EventLive` loads a
  moment list for every row it gets back — so that caller passes a `:limit`.
  `limit: n` takes the *earliest* n by `started_at`, which is also the order
  the results come back in, so a caller that asks for `n + 1` and gets `n + 1`
  knows it was truncated and can say so. Nothing here reports truncation on its
  own: this returns rows, and only the caller knows what it promised the reader.
  """
  @type overlapping_opts :: [limit: pos_integer() | nil]

  @spec overlapping_event(Event.t() | map(), DateTime.t(), overlapping_opts()) :: [Track.t()]
  def overlapping_event(event, now \\ DateTime.utc_now(), opts \\ [])

  def overlapping_event(%{camera_id: camera_id, started_at: started_at} = event, now, opts) do
    event_end = event.ended_at || now

    Track
    |> where([t], t.camera_id == ^camera_id)
    |> where([t], t.started_at <= ^event_end)
    |> where([t], is_nil(t.ended_at) or t.ended_at >= ^started_at)
    |> order_by([t], asc: t.started_at)
    |> maybe_limit(opts[:limit])
    |> Repo.all()
  end

  defp maybe_limit(query, nil), do: query

  defp maybe_limit(query, n) when is_integer(n) and n > 0, do: limit(query, ^n)

  @typedoc """
  Where a moment falls relative to the clip being viewed: inside it, inside
  another surviving clip (with the moment's offset into that clip, in seconds),
  or in no clip at all.
  """
  @type clip_ref :: :here | {:other, String.t(), non_neg_integer()} | :none

  @doc """
  Classifies each instant against the clips that survive on one camera.

  Containment, not overlap: an instant belongs to the clip whose window covers
  it — `started_at <= at <= ended_at`, with a NULL `ended_at` meaning the clip
  is still recording and so contains everything after its start. Clips on a
  camera do not overlap in practice; should two contain the same instant, the
  one that started earlier wins, and `current_event_id` beats both.

  One query for a whole panel's worth of moments, whatever the track count: the
  clips that could contain *any* of the instants are fetched in one go (bounded
  by the camera and the outermost instants), and the per-instant match runs in
  Elixir — the same two-pass shape, and the same reasoning, as
  `first_overlapping_event_ids/2`.

  Keyed by the instant rather than by a moment id, because the caller has
  moments the `track_events` table never held: a track's `ended_at` is a row on
  the track, and it renders as a moment like any other.

  `{:other, event_id, seconds}` carries the offset because the caller cannot
  compute it — that is the *other* clip's `started_at`, which only this query
  read. `:here` carries none: the caller holds the current event and measures
  offsets from it exactly as the detections timeline does.
  """
  @spec moment_clips([DateTime.t()], String.t(), String.t() | nil) :: %{
          DateTime.t() => clip_ref()
        }
  def moment_clips(instants, camera_id, current_event_id)

  def moment_clips([], _camera_id, _current_event_id), do: %{}

  def moment_clips(instants, camera_id, current_event_id) when is_list(instants) do
    instants = Enum.uniq(instants)
    first = Enum.min(instants, DateTime)
    last = Enum.max(instants, DateTime)

    clips =
      Event
      |> where([e], e.camera_id == ^camera_id)
      |> where([e], e.started_at <= ^last)
      |> where([e], is_nil(e.ended_at) or e.ended_at >= ^first)
      |> order_by([e], asc: e.started_at)
      |> select([e], %{id: e.id, started_at: e.started_at, ended_at: e.ended_at})
      |> Repo.all()

    Map.new(instants, &{&1, classify(&1, clips, current_event_id)})
  end

  defp classify(at, clips, current_event_id) do
    case Enum.filter(clips, &contains?(&1, at)) do
      [] ->
        :none

      containing ->
        if Enum.any?(containing, &(&1.id == current_event_id)) do
          :here
        else
          # No clamp on the offset: this branch is only reached for a clip
          # `contains?/2` accepted, which already required `clip.started_at <=
          # at`, so the difference cannot come out negative.
          clip = hd(containing)
          {:other, clip.id, DateTime.diff(at, clip.started_at)}
        end
    end
  end

  defp contains?(clip, at) do
    DateTime.compare(clip.started_at, at) != :gt and
      (is_nil(clip.ended_at) or DateTime.compare(clip.ended_at, at) != :lt)
  end

  @doc """
  Every distinct non-nil track label, sorted — the label filter's options.

  Deliberately the `tracks` table and not `Cairn.Events.known_labels/0`: a label
  that only ever appeared on tracks nothing recorded has no event row to be read
  out of, and those are the rows this page exists to show.

  Both the `DISTINCT` and the sort happen in SQLite. The filter needs a handful
  of options and the table keeps a row per tracked object for 365 days, so
  what must never cross into the BEAM is the row count: this returns as many
  values as there are labels, whatever the table's size.
  """
  @spec known_labels() :: [String.t()]
  def known_labels do
    Track
    |> where([t], not is_nil(t.label))
    |> distinct(true)
    |> select([t], t.label)
    |> order_by([t], asc: t.label)
    |> Repo.all()
  end

  @doc """
  Every distinct zone named by any track, sorted — the zone filter's options.

  `zones` is a `{:array, :string}` column that ecto_sqlite3 stores as JSON
  text, so reaching inside it takes the same `json_each` walk the `zone:` filter
  uses — here as a join, so that `DISTINCT` and `ORDER BY` are the database's
  work. The alternative (select the column, `Enum.concat |> Enum.uniq` in
  Elixir) decodes one JSON array per row of a 365-day table to fill a `<select>`
  with six options; the cost of that is the row count, not the column.
  """
  @spec known_zones() :: [String.t()]
  def known_zones do
    Track
    |> join(:inner, [t], z in fragment("json_each(?)", t.zones), on: true)
    |> distinct(true)
    |> select([_t, z], type(z.value, :string))
    |> order_by([_t, z], asc: z.value)
    |> Repo.all()
  end

  @doc "Filterable, offset-paginated track list, newest first."
  @spec list(list_opts()) :: %{tracks: [Track.t()], page: pos_integer(), total: non_neg_integer()}
  def list(opts \\ []) do
    page = max(Keyword.get(opts, :page, 1), 1)
    page_size = min(Keyword.get(opts, :page_size, 50), 200)

    query =
      Track
      |> filter_camera(opts[:camera])
      |> filter_label(opts[:label])
      |> filter_time(opts[:from], opts[:to])
      |> filter_zone(opts[:zone])
      |> filter_stationary(opts[:min_stationary_ms])

    total = Repo.aggregate(query, :count)

    tracks =
      query
      |> order_by([t], desc: t.started_at)
      |> limit(^page_size)
      |> offset(^((page - 1) * page_size))
      |> Repo.all()

    %{tracks: tracks, page: page, total: total}
  end

  @doc """
  Closes every row still marked live, and returns how many.

  A live row (`ended_at IS NULL`) means a writer opened it and has not closed
  it. Only that writer ever will, so a row whose writer died — the host went
  down mid-track — would sit there for good: `delete_ended_before/1` compares
  against a NULL and never matches it, and the emergency sweep does not touch
  track rows at all. It would read on the page as an object still in frame,
  years later.

  `ended_at` becomes the row's own `updated_at`, the instant it was last known
  live, which for a track being refreshed on the recorder's rhythm is within a
  flush interval of when the host stopped. `updated_at` itself is deliberately
  left alone: it is the evidence `ended_at` is derived from, and re-stamping it
  with the boot's clock would erase it.

  `:host_restart` is the same reason `Cairn.CameraTracker`'s checkpoint
  restore gives the tracks it ends, and for the same event — the two cover
  different sets (a checkpoint holds only the tracks of cameras with an open
  event, and only until the node dies) and overlap without conflict: both write
  `:host_restart`, and `insert_batch/1` is last-write-wins, so a restore that
  lands after this one replaces the derived `ended_at` with the track's own
  `last_seen_at`, which is strictly the better value.
  """
  @spec close_live() :: non_neg_integer()
  def close_live do
    {count, _} =
      Track
      |> where([t], is_nil(t.ended_at))
      |> update([t], set: [ended_at: t.updated_at, end_reason: ^:host_restart])
      |> Repo.update_all([])

    count
  end

  @doc """
  Deletes tracks that ended before `cutoff`, and returns how many.

  Live tracks never match: a comparison against NULL `ended_at` is never true,
  so an unfinished track survives the sweep however old it is. Moments go with
  their track through `ON DELETE CASCADE` — one statement, no second query.
  """
  @spec delete_ended_before(DateTime.t()) :: non_neg_integer()
  def delete_ended_before(cutoff) do
    {count, _} =
      Track
      |> where([t], t.ended_at < ^cutoff)
      |> Repo.delete_all()

    count
  end

  # -- writes -----------------------------------------------------------------

  defp insert_chunked(schema, rows, opts) do
    rows
    |> Enum.chunk_every(@chunk_size)
    |> Enum.reduce(0, fn chunk, acc ->
      {count, nil} = Repo.insert_all(schema, chunk, opts)
      acc + count
    end)
  end

  # Every row of one `insert_all` must carry the identical key set: Ecto builds
  # one header from the union of the rows' keys and passes a nil *cell* for a
  # key a row is missing, which ecto_sqlite3 rejects outright ("Cell-wise
  # default values are not supported on INSERT statements by SQLite3"). Building
  # each row field by field makes the key set constant by construction, and a
  # missing required attr fails as a `KeyError` naming the field rather than as
  # a NOT NULL violation from inside the transaction. `insert_all` does not fill
  # `timestamps()`, hence `now`.
  defp track_row(attrs, now) do
    %{
      id: Map.fetch!(attrs, :id),
      camera_id: Map.fetch!(attrs, :camera_id),
      started_at: attrs |> Map.fetch!(:started_at) |> usec(),
      event_id: attrs[:event_id],
      label: attrs[:label],
      best_score: attrs[:best_score],
      source: attrs[:source],
      plugin_track_id: attrs[:plugin_track_id],
      epoch: attrs[:epoch],
      ended_at: usec(attrs[:ended_at]),
      end_reason: attrs[:end_reason],
      stationary_since: usec(attrs[:stationary_since]),
      stationary_ms: attrs |> Map.get(:stationary_ms, 0) |> whole_ms(),
      entry_bbox: attrs[:entry_bbox],
      exit_bbox: attrs[:exit_bbox],
      best_bbox: attrs[:best_bbox],
      zones: Map.get(attrs, :zones, []),
      inserted_at: now,
      updated_at: now
    }
  end

  defp moment_row(attrs, track_id) do
    %{
      track_id: track_id,
      at: attrs |> Map.fetch!(:at) |> usec(),
      kind: Map.fetch!(attrs, :kind),
      bbox: attrs[:bbox]
    }
  end

  # Every `DateTime` written here lands in a `:utc_datetime_usec` column, and
  # Ecto dumps that type only at precision 6: anything else raises
  # `ArgumentError` from `Ecto.Type.check_usec!`, inside the transaction and
  # inside the caller's process. `insert_all` never casts, so no changeset pads
  # it on the way in — the invariant "a datetime reaching this table already
  # declares microseconds" has to hold at the call site, and the caller is a
  # lossy batch writer whose whole batch dies with it.
  #
  # Wire time is padded where it enters the system
  # (`Cairn.PluginProtocol`, which parses the plugin's three decimals). This
  # restates that at the table so a second time source — a checkpoint restored
  # from an older host, a fixture, a plugin variant — cannot turn a batch into
  # a crash. It pads the declared precision only; the microsecond count is
  # untouched. Anything that is not a `DateTime` passes through to fail on dump
  # as it would have.
  defp usec(%DateTime{microsecond: {value, _digits}} = at),
    do: %{at | microsecond: {value, 6}}

  defp usec(other), do: other

  # Same invariant, second dimension: `stationary_ms` is an `:integer` column,
  # and the tracker's media clock is float arithmetic — a live summary carries
  # `4366.666...`, which `insert_all` dumps strictly (`Ecto.ChangeError`, no
  # cast to save it). The finished-track path never showed this because a
  # track that ended while moving carries the integer 0. Round — the value is
  # milliseconds of stillness; sub-millisecond truth does not exist here.
  defp whole_ms(ms) when is_float(ms), do: round(ms)
  defp whole_ms(ms), do: ms

  # -- filters ----------------------------------------------------------------

  defp filter_camera(query, nil), do: query
  defp filter_camera(query, ""), do: query
  defp filter_camera(query, camera_id), do: where(query, [t], t.camera_id == ^camera_id)

  defp filter_label(query, nil), do: query
  defp filter_label(query, ""), do: query

  # Plain column equality, deliberately without the injection-guard regex
  # `Cairn.Events.list/1` applies to the same option. That guard exists because
  # `Event.labels` is a JSON blob and the label has to be interpolated into a
  # JSONPath string for `json_extract`; here the label is its own column and the
  # value is pinned, so there is no string to build and nothing to guard.
  defp filter_label(query, label), do: where(query, [t], t.label == ^label)

  defp filter_time(query, nil, nil), do: query
  defp filter_time(query, from, nil), do: where(query, [t], t.started_at >= ^from)
  defp filter_time(query, nil, to), do: where(query, [t], t.started_at <= ^to)

  defp filter_time(query, from, to) do
    where(query, [t], t.started_at >= ^from and t.started_at <= ^to)
  end

  # No filter on `event_id`. "Which rows claimed an event id?" is not the same
  # question as "which tracks does a clip hold?" — a track that ended between
  # two clips, or on a stream reset, has a null `event_id` while video of it
  # exists — and only the second question has a page. That one is answered by
  # `first_overlapping_event_ids/2`, on time overlap.

  defp filter_zone(query, nil), do: query
  defp filter_zone(query, ""), do: query

  # `zones` is a `{:array, :string}` column, which ecto_sqlite3 stores as JSON
  # text, so membership is a `json_each` walk rather than a comparison. Like
  # `filter_label/2` above and unlike `Cairn.Events.filter_label/2`, it needs no
  # injection-guard regex: the zone is a pinned bind compared against
  # `json_each.value`, not interpolated into a JSONPath string — there is no
  # string being built and nothing to guard.
  #
  # This has to be SQL: `list/1` counts `total` and pages with limit/offset in
  # the database, so a post-fetch Elixir filter would return short pages and a
  # total that ignores the filter.
  defp filter_zone(query, zone) do
    where(
      query,
      [t],
      fragment(
        "EXISTS (SELECT 1 FROM json_each(?) WHERE json_each.value = ?)",
        t.zones,
        ^zone
      )
    )
  end

  defp filter_stationary(query, nil), do: query
  defp filter_stationary(query, ms), do: where(query, [t], t.stationary_ms >= ^ms)
end
