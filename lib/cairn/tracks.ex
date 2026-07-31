defmodule Cairn.Tracks do
  @moduledoc """
  Track index context — the only module that touches the `tracks` and
  `track_events` tables. The batch writer, the retention sweep and every reader
  go through here.

  The tables exist for one question the event index cannot answer: *what did
  the system see and not record?* `list(recorded: false)` is that query — the
  tracks whose `event_id` is nil never made it into a clip, and because
  `event_id` carries no foreign key it keeps saying "recorded" long after the
  clip itself has aged out.

  `Cairn.Tracks.Track` here is the row, not `Cairn.Track` the runtime broadcast
  struct — the same distinction as `Cairn.Events.Event` and `Cairn.Event`.
  """

  import Ecto.Query

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
          recorded: boolean() | nil,
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

  @doc """
  Writes finished tracks and their timeline moments in one transaction.

  Takes each track paired with its own moments — a list of
  `{track_attrs, [moment_attrs]}`. `track_attrs` is a map with atom keys;
  `:id`, `:camera_id` and `:started_at` are required and everything else is
  optional. Each moment carries `:at`, `:kind` and optionally `:bbox`.

  Moments do **not** carry `:track_id`: it comes from the track they are paired
  with. That is the point of the shape. `track_events.track_id` is a real
  foreign key, so a moment whose parent is not in the same batch would fail the
  insert and take the whole transaction with it — pairing makes that row
  unrepresentable. It also suits a caller that buffers finished tracks in a list
  and their moments in a map keyed by the same id: it zips the two and passes
  the result, and moments it buffered for a track it never finished are simply
  never passed here.

  Tracks insert with `on_conflict: :nothing`: an id can be offered twice — a
  checkpoint restore finalizes tracks as `:host_restart` that a crash-time
  flush may already have written — and the row written
  closer to the events it describes is the one to keep. The conflicting track's
  moments still insert, so that rare race can duplicate moments — harmless in a
  timeline read, and preferable to dropping the audit row.

  Returns `{:ok, %{tracks: n, moments: n}}`, counting rows actually inserted, or
  `{:error, exception}` if SQLite refuses the write (busy, locked, constraint) —
  a value rather than an exit, because the caller is expected to be lossy and
  drop the batch rather than retry against a database that is already
  contended. A refused batch leaves nothing behind: both inserts share one
  transaction.
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
        tracks: insert_chunked(Track, track_rows, on_conflict: :nothing),
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
      |> filter_recorded(opts[:recorded])
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
      started_at: Map.fetch!(attrs, :started_at),
      event_id: attrs[:event_id],
      label: attrs[:label],
      best_score: attrs[:best_score],
      source: attrs[:source],
      plugin_track_id: attrs[:plugin_track_id],
      epoch: attrs[:epoch],
      ended_at: attrs[:ended_at],
      end_reason: attrs[:end_reason],
      stationary_since: attrs[:stationary_since],
      stationary_ms: Map.get(attrs, :stationary_ms, 0),
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
      at: Map.fetch!(attrs, :at),
      kind: Map.fetch!(attrs, :kind),
      bbox: attrs[:bbox]
    }
  end

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

  # The audit query: `recorded: false` is every track the system saw and never
  # put in a clip.
  defp filter_recorded(query, nil), do: query
  defp filter_recorded(query, true), do: where(query, [t], not is_nil(t.event_id))
  defp filter_recorded(query, false), do: where(query, [t], is_nil(t.event_id))

  defp filter_stationary(query, nil), do: query
  defp filter_stationary(query, ms), do: where(query, [t], t.stationary_ms >= ^ms)
end
