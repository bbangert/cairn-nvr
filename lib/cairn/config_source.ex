defmodule Cairn.ConfigSource do
  @moduledoc """
  The `:config_loader` for dev and prod: YAML supplies the globals, the
  `cameras` table supplies the cameras. The file's cameras are imported into
  rows once, on the first boot that finds no import marker and no rows; that
  boot writes the marker either way, so the latch arms even when the file
  lists no cameras. After it the rows are the source of truth and the file's
  `cameras:` key only earns a warning. The file is never rewritten, renamed
  or deleted — the add-on mounts `/config` read-only and `data_dir` still
  comes from it.

  After the import, a load only reads the rows. A fault that names one camera
  skips that row and warns, so the rest of the fleet keeps running; a
  fleet-level fault — one that no single row owns — fails the load and hands
  back the file's globals, which `Cairn.Config.Server` installs so retention,
  the HA token and the reconciler still run on the operator's settings.

  The skip pass holds N (`fleet_count:`, D-P1) so survivors keep the rung and
  derived rate they already had. A held N that leaves the reduced fleet
  disagreeing is a hard fail, not a silent lowering.
  """

  require Logger

  import Ecto.Query, only: [from: 2]

  alias Cairn.CameraControl
  alias Cairn.Cameras
  alias Cairn.Cameras.Camera
  alias Cairn.Cameras.Setting
  alias Cairn.Config
  alias Cairn.Repo

  @marker_key "yaml_import"

  @spec load(Path.t()) :: Cairn.Config.Server.source_result()
  def load(path) do
    case Config.raw_map(path) do
      {:ok, map} -> load_map(map, path)
      {:error, errors} -> {:error, errors, nil}
    end
  rescue
    # Two faults must degrade rather than crash-loop the root supervisor: a
    # Repo fault (lost or busy connection) and an import the store refuses
    # (a colliding id raises from `Repo.insert!`). `Config.Server.init/1`
    # installs whatever fallback comes back here. The map is re-read because
    # the fault may have come from anywhere below.
    e in [Exqlite.Error, DBConnection.ConnectionError] ->
      degrade(path, "cameras: database read failed: " <> Exception.message(e))

    e in [Ecto.InvalidChangesetError, Ecto.ConstraintError] ->
      degrade(path, "cameras: import failed: " <> describe_import_error(e))
  end

  # `Exception.message/1` on these two interpolates the changeset — including
  # `changes.settings`, which can hold a password just spliced in by an
  # import — into whatever this reaches (a log line, `/config`'s health
  # card). Only the field-error messages (changeset) or the constraint name
  # (constraint) are safe to surface. `@doc false` rather than private only
  # so a test can drive it directly with a constructed exception; nothing
  # outside this module calls it.
  @doc false
  @spec describe_import_error(Exception.t()) ::
          String.t()
  def describe_import_error(%Ecto.InvalidChangesetError{changeset: changeset}) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
  end

  def describe_import_error(%Ecto.ConstraintError{constraint: name}),
    do: "constraint #{name} failed"

  defp degrade(path, message) do
    case Config.raw_map(path) do
      {:ok, map} -> {:error, [message], Config.globals_fallback(map)}
      {:error, _errors} -> {:error, [message], nil}
    end
  end

  # `Cairn.Config.Server.update/3` re-validates the fleet through
  # `Cairn.Cameras.raw_maps/0`, which renders enabled rows only — a disabled
  # row's settings are in front of no validator at all. This puts them in
  # front of one: the enabled fleet plus this row, keeping only this row's own
  # errors.
  #
  # Two classes of error are deliberately dropped. A fleet-level rule the row
  # only trips by being added (capacity, one model per VM) does not bind while
  # the row sits outside the running fleet, and `CamerasLive` already tells
  # the operator; and a fleet-level fault the file has *without* this row is
  # the file's, not this write's. Both are outside
  # `partition_by_camera/1`'s bucket for this id, so keeping only that bucket
  # covers them without a second pass.
  #
  # `@doc false` and public: the caller is `Cairn.Cameras`, from inside the
  # config server's write transaction.
  @doc false
  @spec validate_row(Path.t(), Camera.t()) :: :ok | {:error, [String.t()]}
  def validate_row(path, row) do
    case Config.raw_map(path) do
      {:ok, map} -> row_errors(map, row)
      # An unreadable file fails the load this same transaction is about to
      # run, which rejects the write with the file's errors, not the row's.
      {:error, _errors} -> :ok
    end
  end

  defp row_errors(map, row) do
    {rendered, _warnings} = Cameras.raw_maps()
    candidate = Cameras.render_row(row)

    cameras =
      if Enum.any?(rendered, &(Map.get(&1, "id") == row.id)) do
        Enum.map(rendered, &if(Map.get(&1, "id") == row.id, do: candidate, else: &1))
      else
        rendered ++ [candidate]
      end

    case Config.from_map(Map.put(map, "cameras", cameras)) do
      {:ok, _config, _warnings} ->
        :ok

      {:error, errors} ->
        {per_camera, _fleet} = Config.partition_by_camera(errors)

        case Map.get(per_camera, row.id, []) do
          [] -> :ok
          own -> {:error, own}
        end
    end
  end

  @doc "The import-once marker `%{path, sha256, imported_at}`, or `nil` before the first boot armed it."
  @spec import_marker() :: map() | nil
  def import_marker do
    case Repo.get(Setting, @marker_key) do
      %Setting{value: value} -> value
      nil -> nil
    end
  end

  @doc """
  Replaces every camera row with the file's `cameras:` list — the operator's
  answer to the "changed since they were imported" warning. Serialized and
  validated like any other write through `Cairn.Config.Server.update/3`, so
  a file that fails to load replaces nothing (`{:error, {:write, {:yaml,
  errors}}}`), and one with no cameras to import is refused rather than
  silently emptying the fleet (`{:error, {:write, :no_cameras}}`). A file
  that no longer differs from the marker is refused too (`{:error, {:write,
  :no_drift}}`) — the button's own precondition, re-checked under the write
  lock. Rows the file no longer lists lose their runtime state the way a
  delete does — as the write's `after_apply:`, so the prune belongs to the
  commit rather than to this caller surviving the call. Their control
  tombstones go in inside the write closure, ahead of the row delete, for
  the same reason `Cameras.delete/1`'s does — every hook runs after the
  commit, and a control write that read the config while the rows were still
  there could land in the gap. `after_rollback:` revives them again when the
  write does not commit, since the transaction does not undo a tombstone.
  Survivors are revived on `after_commit:` (a re-inserted id the file lists
  was tombstoned by the closure a moment earlier), with `after_apply:`'s
  revive as the retry — exactly as `Cameras.create/1` does for its own id.
  """
  @spec reimport(Path.t()) :: Cameras.write_result()
  def reimport(path \\ Config.default_path()) do
    ref = make_ref()

    Config.Server.update(Cameras.server(), fn -> replace_rows(path, ref) end,
      after_commit: fn -> revive_remaining() end,
      after_rollback: fn -> revive_deleted(ref) end,
      after_apply: fn _diff -> prune_deleted(ref) end
    )
  end

  # The write closure and all three callbacks run in the config server
  # process, so the deleted ids ride its dictionary — no message hop, and
  # nothing left in a mailbox when the write rolls back. Only this ref's own
  # key is written: a failed `after_rollback:` is retried under its original
  # ref for up to 5 s, and another re-import can run in between, so sweeping
  # older keys here would empty a stash a retry still has to read. Each
  # callback deletes its own key; one outlives its write only when every
  # retry raised — a few ids, left to the restart-time reconciliation
  # follow-up.
  defp stash_deleted(ref, ids), do: Process.put({:reimport_deleted, ref}, ids)

  # The rollback undid the row deletes; these ids are back, so the tombstones
  # the closure installed for them have to come off too.
  #
  # Guarded on the row rather than reviving unconditionally: this callback
  # can be retried up to 5 s later (`retry_rollback/3`), and a genuine, later
  # delete of the same id can commit inside that window — a bare revive would
  # then clear that newer delete's tombstone instead of only this write's own.
  #
  # The stash is dropped only once every revive above has returned, not
  # before: `CameraControl.revive/1` exiting mid-loop propagates out of this
  # whole callback, which the server retries from the top, and a stash
  # cleared any earlier would lose the ids the aborted pass never reached.
  # On this path there is no `after_apply:` to drop it instead.
  defp revive_deleted(ref) do
    deleted = stashed_deleted(ref)
    Enum.each(deleted, fn id -> if Cameras.get(id), do: CameraControl.revive(id) end)
    Process.delete({:reimport_deleted, ref})
  end

  defp revive_remaining, do: Enum.each(Cameras.list(), &CameraControl.revive(&1.id))

  defp stashed_deleted(ref), do: Process.get({:reimport_deleted, ref}, [])

  # The pruned set is the rows the write itself deleted, minus what is there
  # now: a row another session added between the call and the transaction is
  # in neither the deleted list nor the applied diff — a disabled row is in
  # no config at all, and D-P8 keys prunes on the row rather than the diff.
  # A re-import bypasses `Cameras.create/1`, so an id it re-inserts after an
  # earlier delete would stay tombstoned in `CameraControl` (by the closure's
  # own tombstone, same as an ordinary delete) and refuse every control
  # write. `after_commit:`'s `revive_remaining/0` has already brought the
  # survivors back; this repeat is the retry for the case that one raised,
  # which `run_zero_arity/2` swallows — the same reason `Cameras.create/1`
  # revives on both hooks. The stash is deleted here, not read: this is the
  # last callback on `ref`.
  defp prune_deleted(ref) do
    deleted = stashed_deleted(ref)
    Process.delete({:reimport_deleted, ref})
    remaining = Enum.map(Cameras.list(), & &1.id)
    Enum.each(deleted -- remaining, &Cameras.prune_runtime/1)
    Enum.each(remaining, &CameraControl.revive/1)
  end

  defp replace_rows(path, ref) do
    with {:ok, map} <- Config.raw_map(path),
         {:ok, cameras} <- importable_list(Map.get(map, "cameras")),
         :ok <- check_drift(cameras),
         {:ok, _config, _warnings} <- Config.from_map(map) do
      before = Repo.all(from(c in Camera, select: c.id))
      # Only the ids the file no longer lists are "deleted": a survivor is
      # replaced row for row and keeps its runtime state — its control
      # overlay included — exactly as an edit would leave it. Stashed and
      # tombstoned before the delete, not after it: a control write that read
      # the old config could otherwise land between the commit and any hook.
      deleted = before -- Enum.map(cameras, &Map.get(&1, "id"))
      stash_deleted(ref, deleted)
      Enum.each(deleted, &CameraControl.tombstone/1)
      Repo.delete_all(Camera)
      Repo.delete_all(from(s in Setting, where: s.key == @marker_key))
      # The write closure answers only `:ok`; the dropped-key warnings from
      # the import are logged here so they are not lost with it.
      cameras |> import_rows(path) |> Enum.each(&Logger.warning("config: #{&1}"))
      :ok
    else
      {:error, errors} when is_list(errors) -> {:error, {:yaml, errors}}
      {:error, reason} when reason in [:no_cameras, :no_drift, :no_marker] -> {:error, reason}
    end
  end

  # Two `/config` sessions can each queue a re-import while both see the
  # drift warning; the second would replace the fleet the first already
  # imported, discarding any edit made in between. The check reads the marker
  # inside the write closure — which runs in the config server's
  # `mode: :immediate` transaction — so the first import's new marker is
  # already committed and visible when the second one looks.
  # No marker means no prior import to drift from: the button is never shown
  # for that state, so a request that reaches here anyway (a crafted event, a
  # direct call) is refused rather than allowed to replace the fleet.
  defp check_drift(cameras) do
    case import_marker() do
      %{"sha256" => sha} -> if cameras_sha(cameras) == sha, do: {:error, :no_drift}, else: :ok
      _no_marker -> {:error, :no_marker}
    end
  end

  # The same three shapes `import_once/3` tells apart: a malformed key is the
  # file's fault, not "nothing to import".
  defp importable_list(cameras) when is_list(cameras) and cameras != [], do: {:ok, cameras}
  defp importable_list(cameras) when is_nil(cameras) or cameras == [], do: {:error, :no_cameras}
  defp importable_list(_other), do: {:error, ["cameras must be a list"]}

  defp load_map(map, path) do
    marker = import_marker()

    case import_once(map, path, marker) do
      {:ok, import_warnings} ->
        {rendered, render_warnings} = Cameras.raw_maps()
        drift = drift_warnings(map, path, marker || import_marker())
        render(map, rendered, Cameras.list(), import_warnings ++ render_warnings ++ drift)

      {:error, errors} ->
        {:error, errors, Config.globals_fallback(map)}
    end
  end

  # -- import once ------------------------------------------------------------

  # The marker is the latch, so a first boot always writes one — a file with
  # no `cameras:` key included. Without that, a `cameras:` key added after the
  # operator has made rows through the UI would import into a populated table
  # on the next boot, and the colliding ids crash the boot.
  #
  # Rows that exist with no marker were made some other way and are never
  # overwritten: the latch arms and the file's cameras are left alone.
  #
  # The whole YAML is validated before an import: a file that cannot load
  # imports nothing and writes no marker, so the operator fixes it and the
  # next boot imports — today's behaviour, not a half-migrated database.
  #
  # A present `cameras:` that isn't a list fails the same way, marker or not:
  # the render below would otherwise overwrite it with the rendered rows and
  # the bad value would silently disappear instead of degrading like any
  # other YAML error.
  defp import_once(map, path, marker) do
    cameras = Map.get(map, "cameras")

    cond do
      not is_nil(cameras) and not is_list(cameras) ->
        {:error, ["cameras must be a list"]}

      not is_nil(marker) ->
        {:ok, []}

      not importable?(cameras) ->
        arm(cameras, path)
        {:ok, []}

      Repo.aggregate(Camera, :count) > 0 ->
        arm(cameras, path)

        {:ok,
         [
           "#{Path.basename(path)}: cameras were not imported — the database already has " <>
             "rows; remove the key or use Import on /config"
         ]}

      true ->
        case Config.from_map(map) do
          {:ok, _config, _warnings} -> {:ok, import_rows(cameras, path)}
          {:error, errors} -> {:error, errors}
        end
    end
  end

  # An empty list lists nothing, so it is the same as an absent key.
  defp importable?(cameras), do: is_list(cameras) and cameras != []

  defp arm(cameras, path) do
    Repo.insert!(marker_changeset(if(is_list(cameras), do: cameras, else: []), path))
  end

  defp import_rows(cameras, path) do
    {rows, warnings} =
      cameras
      |> Enum.with_index()
      |> Enum.map_reduce([], &import_row/2)

    {:ok, _result} =
      Repo.transaction(fn ->
        Enum.each(rows, &Repo.insert!/1)
        Repo.insert!(marker_changeset(cameras, path))
      end)

    Logger.info("config: imported #{length(rows)} camera(s) from #{path} into the database")
    warnings
  end

  # Unknown keys are dropped at import rather than stored: a stored unknown key
  # warns on every boot with no form field to remove it. The render-time drop
  # in `Cameras.raw_maps/0` stays as the backstop for keys a release retires.
  defp import_row({raw, index}, warnings) do
    known = Config.Camera.known_keys()
    id = Map.get(raw, "id")

    dropped =
      for key <- Map.keys(raw),
          key not in known,
          do: "camera #{id}: dropped unknown key #{inspect(key)}"

    changeset =
      Camera.changeset(%Camera{}, %{
        id: id,
        position: index,
        enabled: true,
        settings: raw |> Map.take(known) |> Cameras.canonical(),
        # The whole file went through `from_map/1` before this import, so the
        # zones stored here are exactly what it said and already valid.
        zones: Map.get(raw, "zones", [])
      })

    {changeset, warnings ++ dropped}
  end

  # The hash covers the `cameras` list, not the file: the drift warning tells
  # the operator to *remove* the key, and removing it must not itself read as
  # "changed since import".
  defp marker_changeset(cameras, path) do
    Setting.changeset(%Setting{}, %{
      key: @marker_key,
      value: %{
        "path" => path,
        "sha256" => cameras_sha(cameras),
        "imported_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }
    })
  end

  defp cameras_sha(cameras) do
    :crypto.hash(:sha256, Jason.encode!(sort_keys(cameras))) |> Base.encode16(case: :lower)
  end

  # The same YAML must hash the same across boots, and map iteration order is
  # not a promise the runtime makes.
  defp sort_keys(map) when is_map(map) do
    %Jason.OrderedObject{
      values:
        map
        |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
        |> Enum.map(fn {key, value} -> {key, sort_keys(value)} end)
    }
  end

  defp sort_keys(list) when is_list(list), do: Enum.map(list, &sort_keys/1)
  defp sort_keys(other), do: other

  defp drift_warnings(map, path, marker) do
    base = Path.basename(path)

    case {Map.get(map, "cameras"), marker} do
      # `cameras: []` lists nothing, so it earns neither warning.
      {cameras, %{"sha256" => sha}} when is_list(cameras) and cameras != [] ->
        if cameras_sha(cameras) == sha do
          ["#{base} still lists cameras: — the database is the source of truth; remove the key"]
        else
          [
            "#{base}: cameras changed since they were imported — use Import again on /config " <>
              "to replace them, or remove the key"
          ]
        end

      _no_key_or_no_marker ->
        []
    end
  end

  # -- render -----------------------------------------------------------------

  defp render(map, rendered, rows, warnings) do
    case Config.from_map(Map.put(map, "cameras", rendered)) do
      {:ok, config, load_warnings} ->
        {:ok, %{config | dormant: dormant(rows, [])}, warnings ++ load_warnings, %{}}

      {:error, errors} ->
        {per_camera, fleet} = Config.partition_by_camera(errors)

        if fleet == [] do
          retry(map, rendered, rows, warnings, errors, per_camera)
        else
          {:error, errors, fallback(map, rows)}
        end
    end
  end

  defp retry(map, rendered, rows, warnings, errors, per_camera) do
    skipped_ids = Map.keys(per_camera)
    # Held N (D-P1): the pass-1 detecting count, which is the previous good
    # load's N whenever the only change is one row drifting bad — the case the
    # hold exists for. A row that failed inside `Camera.parse` still carries
    # its `"plugin"` key here, so this over-counts by at most the skipped
    # rows, which is the conservative side of every capacity check.
    held_n = Enum.count(rendered, &(Map.get(&1, "plugin") != nil))
    survivors = Enum.reject(rendered, &(Map.get(&1, "id") in skipped_ids))

    case Config.from_map(Map.put(map, "cameras", survivors), fleet_count: held_n) do
      {:ok, config, load_warnings} ->
        skips =
          for {id, errs} <- Enum.sort_by(per_camera, &elem(&1, 0)),
              do: "camera #{id}: skipped — #{Enum.join(errs, "; ")}"

        {:ok, %{config | dormant: dormant(rows, skipped_ids)}, warnings ++ load_warnings ++ skips,
         per_camera}

      # A backstop, not the working path: holding N makes camera removal
      # monotone for every fleet rule the spike enumerated — one-model-per-VM
      # was the sole non-monotone one, and it was non-monotone only through N.
      # A pass-2 failure therefore means a rule nobody has classified yet, and
      # carries both lists rather than being swallowed.
      {:error, retry_errors} ->
        {:error, errors ++ retry_errors, fallback(map, rows)}
    end
  end

  # Every row rides a failed load as dormant, not only the skipped ones: no
  # camera loaded at all means every row's clips would otherwise fall back to
  # the global days.
  defp fallback(map, rows) do
    case Config.globals_fallback(map) do
      %Config{} = config -> %{config | dormant: dormant(rows, Enum.map(rows, & &1.id))}
      nil -> nil
    end
  end

  # Only the retention block is read off a row here: a row that is dormant
  # because it was skipped can be malformed anywhere, and a malformed
  # override is itself one of the reasons it may have been skipped.
  defp dormant(rows, skipped_ids) do
    for row <- rows, not row.enabled or row.id in skipped_ids do
      retention = Map.get(row.settings, "retention")

      %Config.Camera{
        id: row.id,
        retention_days: retention_days(retention),
        retention_per_label: retention_per_label(retention)
      }
    end
  end

  defp retention_days(%{"days" => days}) when is_integer(days), do: days
  defp retention_days(_other), do: nil

  # A dormant row is never rendered, so the parser never validates it — a
  # string here would raise inside the hourly sweep instead.
  defp retention_per_label(%{"per_label" => per_label}) when is_map(per_label) do
    for {label, days} <- per_label,
        is_binary(label) and is_integer(days),
        into: %{},
        do: {label, days}
  end

  defp retention_per_label(_other), do: %{}
end
