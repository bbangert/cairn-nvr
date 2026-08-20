defmodule Cairn.Events do
  @moduledoc """
  Event index context — the only module that touches the `events` table.
  The camera trackers/extractor/reconciler/retention all go through here.
  """

  import Ecto.Query

  alias Cairn.DataDir
  alias Cairn.Events.Event
  alias Cairn.Repo

  @type list_opts :: [
          camera: String.t() | nil,
          label: String.t() | nil,
          from: DateTime.t() | nil,
          to: DateTime.t() | nil,
          page: pos_integer(),
          page_size: pos_integer()
        ]

  @spec get(String.t()) :: Event.t() | nil
  def get(id), do: Repo.get(Event, id)

  @doc "Inserts the `active` row at event start (crash-safe reconciliation)."
  @spec create_active(Cairn.Event.t(), Path.t()) ::
          {:ok, Event.t()} | {:error, Ecto.Changeset.t()}
  def create_active(%Cairn.Event{} = event, path) do
    %Event{}
    |> Event.changeset(%{
      id: event.id,
      camera_id: event.camera_id,
      started_at: event.started_at,
      status: :active,
      path: path,
      labels: labels_map(event)
    })
    |> Repo.insert()
  end

  @spec finalize(Cairn.Event.t(), non_neg_integer()) ::
          {:ok, Event.t()} | {:error, term()}
  def finalize(%Cairn.Event{} = event, bytes), do: close(event, bytes, :finalized)

  @doc """
  Closes an event that produced no playable clip — every field `finalize/2`
  writes, but `partial` rather than `finalized`.

  `Cairn.EventExtractor` uses it for an event no keyframe ever reached: the
  file it leaves on disk holds an init segment and no samples, which is the
  same "there is a file but it is not a whole clip" state a recording
  interrupted by a crash lands in, and the status the UI, the read API and
  boot reconciliation already read that way. `finalized` would claim media the
  file does not hold.
  """
  @spec finalize_partial(Cairn.Event.t(), non_neg_integer()) ::
          {:ok, Event.t()} | {:error, term()}
  def finalize_partial(%Cairn.Event{} = event, bytes), do: close(event, bytes, :partial)

  defp close(event, bytes, status) do
    case get(event.id) do
      nil ->
        {:error, :not_found}

      row ->
        row
        |> Event.changeset(%{
          status: status,
          ended_at: event.ended_at,
          bytes: bytes,
          labels: labels_map(event),
          max_score: event.max_score
        })
        |> Repo.update()
    end
  end

  @spec mark_partial(String.t(), map()) :: {:ok, Event.t()} | {:error, term()}
  def mark_partial(id, attrs \\ %{}) do
    case get(id) do
      nil -> {:error, :not_found}
      row -> row |> Event.changeset(Map.put(attrs, :status, :partial)) |> Repo.update()
    end
  end

  @spec set_snapshot(String.t(), Path.t()) :: {:ok, Event.t()} | {:error, term()}
  def set_snapshot(id, snapshot_path) do
    case get(id) do
      nil -> {:error, :not_found}
      row -> row |> Event.changeset(%{snapshot_path: snapshot_path}) |> Repo.update()
    end
  end

  @doc "Adopts an orphaned clip found on disk as a `partial` event."
  @spec adopt_orphan(String.t(), String.t(), DateTime.t(), Path.t(), non_neg_integer()) ::
          {:ok, Event.t()} | {:error, Ecto.Changeset.t()}
  def adopt_orphan(event_id, camera_id, started_at, path, bytes) do
    %Event{}
    |> Event.changeset(%{
      id: event_id,
      camera_id: camera_id,
      started_at: started_at,
      status: :partial,
      path: path,
      bytes: bytes
    })
    |> Repo.insert()
  end

  @doc "Filterable, offset-paginated event list, newest first."
  @spec list(list_opts()) :: %{events: [Event.t()], page: pos_integer(), total: non_neg_integer()}
  def list(opts \\ []) do
    page = max(Keyword.get(opts, :page, 1), 1)
    page_size = min(Keyword.get(opts, :page_size, 50), 200)

    query =
      Event
      |> filter_camera(opts[:camera])
      |> filter_label(opts[:label])
      |> filter_time(opts[:from], opts[:to])

    total = Repo.aggregate(query, :count)

    events =
      query
      |> order_by([e], desc: e.started_at)
      |> limit(^page_size)
      |> offset(^((page - 1) * page_size))
      |> Repo.all()

    %{events: events, page: page, total: total}
  end

  @doc "Distinct labels seen across all events (for filter dropdowns)."
  @spec known_labels() :: [String.t()]
  def known_labels do
    Event
    |> select([e], e.labels)
    |> Repo.all()
    |> Enum.flat_map(&Map.keys(Map.get(&1, "max_scores", %{})))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @spec all() :: [Event.t()]
  def all, do: Repo.all(Event)

  @doc """
  One camera's rows still marked `active`.

  For a lane owner asking, at its own start, what it may have left behind: a
  row is `active` only between the extractor's `create_active/2` and its
  finalize, so these are events nothing has closed — the boot-wide version of
  the question `Cairn.Reconciler` answers for every camera at once.
  """
  @spec active_for_camera(String.t()) :: [Event.t()]
  def active_for_camera(camera_id) do
    Event
    |> where([e], e.camera_id == ^camera_id and e.status == :active)
    |> Repo.all()
  end

  @doc "Finished (non-active) events, oldest first — emergency cleanup order."
  @spec oldest_for_cleanup(pos_integer()) :: [Event.t()]
  def oldest_for_cleanup(count) do
    Event
    |> where([e], e.status != :active)
    |> order_by([e], asc: e.started_at)
    |> limit(^count)
    |> Repo.all()
  end

  @doc "Finished events started before `cutoff` (retention candidates)."
  @spec finished_started_before(DateTime.t()) :: [Event.t()]
  def finished_started_before(cutoff) do
    Event
    |> where([e], e.status != :active and e.started_at < ^cutoff)
    |> Repo.all()
  end

  @spec delete_row(Event.t()) :: {:ok, Event.t()} | {:error, term()}
  def delete_row(%Event{} = event), do: Repo.delete(event)

  @doc "Deletes an event whole: its clip file, snapshot, track path, and index row."
  @spec delete(Event.t()) :: {:ok, Event.t()} | {:error, term()}
  def delete(%Event{} = event) do
    if event.path do
      File.rm(event.path)
      # The track-path sidecar is derived from the clip path rather than stored
      # (`Cairn.DataDir.trackpath_for_clip/1`), so removing it needs no column
      # and cannot dangle. Retention prune, emergency cleanup (both
      # `Cairn.Retention.delete_event/1`) and the event page's delete button all
      # route through here. `Cairn.Reconciler` is the one caller that does not:
      # it calls `delete_row/1` directly, for a row whose clip file has already
      # gone missing, and sheds the sidecar itself for the same reason.
      # Events older than the feature simply have no such file, and `File.rm/1`'s
      # error is discarded here exactly as the clip's is.
      File.rm(DataDir.trackpath_for_clip(event.path))
    end

    if event.snapshot_path, do: File.rm(event.snapshot_path)
    delete_row(event)
  end

  # -- filters ----------------------------------------------------------------

  defp filter_camera(query, nil), do: query
  defp filter_camera(query, ""), do: query
  defp filter_camera(query, camera_id), do: where(query, [e], e.camera_id == ^camera_id)

  defp filter_label(query, nil), do: query
  defp filter_label(query, ""), do: query

  defp filter_label(query, label) do
    # labels come from plugins ([\w -] in practice); anything else would
    # make json_extract raise on a malformed JSONPath — match nothing instead
    if label =~ ~r/^[a-zA-Z0-9_ -]+$/ do
      path = "$.max_scores.#{label}"
      where(query, [e], not is_nil(fragment("json_extract(?, ?)", e.labels, ^path)))
    else
      where(query, [e], false)
    end
  end

  defp filter_time(query, nil, nil), do: query
  defp filter_time(query, from, nil), do: where(query, [e], e.started_at >= ^from)
  defp filter_time(query, nil, to), do: where(query, [e], e.started_at <= ^to)

  defp filter_time(query, from, to) do
    where(query, [e], e.started_at >= ^from and e.started_at <= ^to)
  end

  defp labels_map(%Cairn.Event{} = event) do
    %{"entries" => event.labels, "max_scores" => event.max_scores}
    |> maybe_put("trigger", event.trigger)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
