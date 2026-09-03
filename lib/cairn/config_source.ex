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
      degrade(path, log_db_error(e, __STACKTRACE__))

    e in [Ecto.InvalidChangesetError, Ecto.ConstraintError] ->
      degrade(path, "cameras: import failed: " <> describe_import_error(e))
  end

  # `Exqlite.Error` carries the failing `statement`, which holds the values
  # just spliced into `settings` — an RTSP password among them — and both
  # `Exception.message/1` and `Exception.format/3` render it. So neither is
  # used on the way to the log either: the line is assembled from the module
  # and the driver's own message, with the statement left out on purpose, and
  # the surfaced text stays generic. `@doc false` rather than private so a
  # test can drive it directly, the same reason `describe_import_error/1` is.
  @doc false
  @spec log_db_error(Exception.t(), Exception.stacktrace()) :: String.t()
  def log_db_error(%module{} = e, stacktrace) do
    Logger.error(
      "cameras: database access failed: #{inspect(module)}: #{inspect(Map.get(e, :message))}\n" <>
        Exception.format_stacktrace(stacktrace)
    )

    "cameras: database access failed"
  end

  # `Exception.message/1` on these two interpolates the changeset — including
  # `changes.settings`, which can hold a password just spliced in by an
  # import — into whatever this reaches (a log line, `/config`'s health
  # card). Only the field-error messages (changeset) or the constraint name
  # (constraint) are safe to surface. `@doc false` rather than private only
  # so a test can drive it directly with a constructed exception; nothing
  # outside this module calls it.
  @doc false
  @spec describe_import_error(Exception.t()) :: String.t()
  def describe_import_error(%Ecto.InvalidChangesetError{changeset: changeset}) do
    changeset
    |> Ecto.Changeset.traverse_errors(&interpolate/1)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
  end

  def describe_import_error(%Ecto.ConstraintError{constraint: name}),
    do: "constraint #{name} failed"

  # Converted only on a hit, and through `inspect/1` for anything not
  # `String.Chars`: a cast error carries metadata like `type: {:array,
  # :string}` that no message interpolates, and converting every option
  # eagerly raised here — inside the rescue whose whole job is to turn an
  # import failure into text.
  defp interpolate({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _match -> printable(value) end)
    end)
  end

  defp printable(value) do
    if String.Chars.impl_for(value), do: to_string(value), else: inspect(value)
  end

  defp degrade(path, message) do
    case Config.raw_map(path) do
      {:ok, map} -> {:error, [message], Config.globals_fallback(map)}
      {:error, _errors} -> {:error, [message], nil}
    end
  end

  # The config page reads it in phase 3.
  @doc false
  @spec import_marker() :: map() | nil
  def import_marker do
    case Repo.get(Setting, @marker_key) do
      %Setting{value: value} -> value
      nil -> nil
    end
  end

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

  # `:none` for an absent or empty `cameras:` key or no marker to compare
  # against — `cameras: []` lists nothing, so it earns neither warning, the
  # same reading `import_once/3`'s `importable?/1` gives it. `:same` and
  # `:changed` classify the two states `drift_warnings/3` renders; kept apart
  # so the classification has no strings to build.
  defp drift(cameras, marker)

  defp drift(cameras, %{"sha256" => sha}) when is_list(cameras) and cameras != [] do
    if cameras_sha(cameras) == sha, do: :same, else: :changed
  end

  defp drift(_cameras, _marker), do: :none

  defp drift_warnings(map, path, marker) do
    base = Path.basename(path)

    case drift(Map.get(map, "cameras"), marker) do
      :same ->
        ["#{base} still lists cameras: — the database is the source of truth; remove the key"]

      :changed ->
        [
          "#{base}: cameras changed since they were imported — use Import again on /config " <>
            "to replace them, or remove the key"
        ]

      :none ->
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
