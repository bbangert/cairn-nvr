defmodule Cairn.Cameras do
  @moduledoc """
  Cameras live as rows; `raw_maps/0` renders them into the `"cameras"` key of
  the YAML-shaped map in front of `Cairn.Config.from_map/1`.

  Every write goes through `Cairn.Config.Server.update/3`, whose transaction
  re-renders and re-validates the whole fleet: a save the validator rejects
  never lands, so the cross-camera rules (one model per VM, ladder capacity)
  hold on the rows and not only on what a form could see. A write that puts a
  row in front of the parser as the operator's own act — `create/1`,
  `update/2`, `put_zones/2`, `set_enabled(id, true)` — passes it as
  `reject_skipped:`, so a save cannot leave its own row skipped and dark.
  `delete/1`, `reorder/1` and a disable do not: none of them asks the parser
  to accept a row the operator just wrote.
  """

  # `only:` — `Ecto.Query.update/2` would clash with this module's own.
  import Ecto.Query, only: [from: 2]

  alias Cairn.CameraControl
  alias Cairn.Cameras.Camera
  alias Cairn.CameraStatus
  alias Cairn.Config
  alias Cairn.EventCheckpoint
  alias Cairn.PresenceCheckpoint
  alias Cairn.Repo

  @typedoc """
  What `Cairn.Config.Server.update/3` answers: the applied diff and its
  warnings, the validator's errors, or the write's own failure (a changeset,
  `:not_found`, a DB fault).
  """
  @type write_result ::
          {:ok, Cairn.Config.Server.diff(), [String.t()]}
          | {:error, [String.t()]}
          | {:error, {:write, term()}}

  @spec list() :: [Camera.t()]
  def list do
    Repo.all(from c in Camera, order_by: [asc: c.position, asc: c.id])
  end

  @spec get(String.t()) :: Camera.t() | nil
  def get(id), do: Repo.get(Camera, id)

  @doc """
  The config server cameras reload through. LiveView/context tests point
  this at a private DB-backed server (plan D-P7) because the test singleton
  keeps the file source.
  """
  @spec server() :: module() | pid()
  def server, do: Application.get_env(:cairn, :config_server, Cairn.Config.Server)

  @doc """
  Adds a camera at the end of the fleet. `attrs` are the row's columns —
  `"id"`, `"enabled"` (default true), `"settings"` (a YAML-camera-shaped map,
  normalized through `canonical/1`) and `"zones"` — string- or atom-keyed.
  """
  @spec create(map()) :: write_result()
  def create(attrs) do
    attrs = stringify_shallow(attrs)
    id = Map.get(attrs, "id")

    write = fn ->
      changeset =
        Camera.changeset(%Camera{}, %{
          id: id,
          # Read inside the closure, so it sees the row a save still ahead of
          # this one in the server's mailbox has already committed.
          position: next_position(),
          enabled: Map.get(attrs, "enabled", true),
          settings: attrs |> Map.get("settings") |> canonical_settings(),
          zones: Map.get(attrs, "zones", [])
        })

      with {:ok, _row} <- Repo.insert(changeset), do: :ok
    end

    Config.Server.update(server(), write, reject_skipped: id)
  end

  @doc """
  Writes `attrs` (`"position"`, `"enabled"`, `"settings"`, `"zones"`) onto an
  existing row. The id is immutable, so it is not among them.
  """
  @spec update(String.t(), map()) :: write_result()
  def update(id, attrs) do
    changes =
      attrs
      |> stringify_shallow()
      |> Map.take(~w(position enabled settings zones))
      |> canonicalize_settings()

    Config.Server.update(server(), fn -> update_row(id, changes) end, reject_skipped: id)
  end

  defp update_row(id, changes) do
    case get(id) do
      nil -> {:error, :not_found}
      camera -> with {:ok, _row} <- Repo.update(Camera.update_changeset(camera, changes)), do: :ok
    end
  end

  defp canonicalize_settings(changes) do
    case Map.fetch(changes, "settings") do
      {:ok, settings} -> Map.put(changes, "settings", canonical_settings(settings))
      :error -> changes
    end
  end

  @doc """
  Flips a camera's `enabled` column. A disable is a fleet edit like any
  other: the validator sees the fleet without the camera and can refuse it.
  """
  @spec set_enabled(String.t(), boolean()) :: write_result()
  # Enabling puts the row back in front of the parser, so it carries the same
  # bar a create does; a disabled row is not rendered and cannot be skipped.
  def set_enabled(id, true), do: update(id, %{"enabled" => true})

  def set_enabled(id, false) do
    Config.Server.update(server(), fn -> update_row(id, %{"enabled" => false}) end)
  end

  @spec put_zones(String.t(), [map()]) :: write_result()
  def put_zones(id, zones) when is_list(zones), do: update(id, %{"zones" => zones})

  @doc """
  Renumbers `position` to the order of `ids`, which must name every row
  exactly once.
  """
  @spec reorder([String.t()]) :: write_result()
  def reorder(ids) when is_list(ids) do
    Config.Server.update(server(), fn ->
      # A partial list would leave the omitted rows on their old positions,
      # colliding with the new indices; `list/0`'s id tiebreak hides the tie,
      # so the fleet's order would silently stop matching what was asked for.
      if whole_fleet?(ids), do: reposition_all(ids), else: {:error, :incomplete}
    end)
  end

  defp whole_fleet?(ids), do: Enum.sort(ids) == list() |> Enum.map(& &1.id) |> Enum.sort()

  defp reposition_all(ids) do
    ids
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {id, index}, :ok -> reposition(id, index) end)
  end

  defp reposition(id, index) do
    case get(id) do
      nil ->
        {:halt, {:error, :not_found}}

      camera ->
        case Repo.update(Camera.update_changeset(camera, %{position: index})) do
          {:ok, _row} -> {:cont, :ok}
          {:error, changeset} -> {:halt, {:error, changeset}}
        end
    end
  end

  @doc """
  Deletes a camera and clears its live runtime state — status, control
  overlay and both event checkpoints.
  """
  @spec delete(String.t()) :: write_result()
  def delete(id) do
    case Config.Server.update(server(), fn -> delete_row(id) end) do
      {:ok, _diff, _warnings} = applied ->
        prune_runtime(id)
        applied

      rejected ->
        rejected
    end
  end

  defp delete_row(id) do
    case get(id) do
      nil -> {:error, :not_found}
      camera -> with {:ok, _row} <- Repo.delete(camera), do: :ok
    end
  end

  # Keyed on the row delete and never on `diff.removed` (D-P8): a skipped or
  # disabled camera is absent from the config too, and it must keep its
  # control override and last status. Event rows and clip files stay under
  # the old id until retention sweeps them.
  defp prune_runtime(id) do
    remaining = Enum.map(list(), & &1.id)
    CameraStatus.prune(remaining)
    CameraControl.prune(remaining)
    PresenceCheckpoint.delete(id)
    EventCheckpoint.delete(id)
  end

  defp next_position do
    case Repo.aggregate(Camera, :max, :position) do
      nil -> 0
      max -> max + 1
    end
  end

  defp canonical_settings(nil), do: %{}
  defp canonical_settings(settings) when is_map(settings), do: canonical(settings)

  # A malformed "settings" param must surface as a changeset error from
  # Camera.changeset/2's cast, not a FunctionClauseError inside the server's
  # write transaction.
  defp canonical_settings(settings), do: settings

  @doc """
  Enabled rows, in `list/0` order, rendered to YAML-camera-shaped maps —
  `{maps, warnings}`. A load is read-only: an unknown settings key is
  warned and dropped from the rendered map, never rewritten on the row
  (retired keys change rows only by migration).
  """
  @spec raw_maps() :: {[map()], [String.t()]}
  def raw_maps do
    known = Config.Camera.known_keys()

    list()
    |> Enum.filter(& &1.enabled)
    |> Enum.map_reduce([], fn camera, warnings ->
      unknown = Map.keys(camera.settings) -- known

      warnings =
        Enum.reduce(unknown, warnings, fn key, acc ->
          ["camera #{camera.id}: dropped unknown key #{inspect(key)}" | acc]
        end)

      map =
        camera.settings
        |> Map.take(known)
        |> Map.put("id", camera.id)

      # `"zones"` is not rendered here: `Config.Camera` learns the key in
      # phase 2 (P2-T1) — rendering it now would warn "unknown key" on
      # every boot.

      {map, warnings}
    end)
    |> then(fn {maps, warnings} -> {maps, Enum.reverse(warnings)} end)
  end

  @doc """
  Normalizes a YAML-camera-shaped map (string or atom keys) to what a row's
  `settings` column holds. The one path both the YAML importer and the edit
  form write settings through (plan D-P5), so an untouched save renders
  byte-identically and diffs to nothing. Idempotent:
  `canonical(canonical(m)) == canonical(m)`.
  """
  @spec canonical(map()) :: map()
  def canonical(map) when is_map(map) do
    map
    |> stringify_shallow()
    |> Enum.reduce(%{}, fn {key, value}, acc -> canonical_put(acc, key, value) end)
  end

  # `id` and `zones` live in their own columns; a bare YAML key parses as
  # nil, which the parser already treats as absent.
  defp canonical_put(acc, key, _value) when key in ["id", "zones"], do: acc
  defp canonical_put(acc, _key, nil), do: acc

  defp canonical_put(acc, "min_score", value) do
    Map.put(acc, "min_score", canonical_min_score(value))
  end

  defp canonical_put(acc, key, value) when key in ["track", "record"] do
    case canonical_tier(value) do
      nil -> acc
      tier -> Map.put(acc, key, tier)
    end
  end

  defp canonical_put(acc, "extra_ffmpeg_args", value) do
    Map.put(acc, "extra_ffmpeg_args", canonical_extra_args(value))
  end

  defp canonical_put(acc, "motion_json", value) do
    Map.put(acc, "motion_json", canonical_motion_json(value))
  end

  defp canonical_put(acc, "retention", value) do
    case canonical_retention(value) do
      nil -> acc
      retention -> Map.put(acc, "retention", retention)
    end
  end

  defp canonical_put(acc, key, value), do: Map.put(acc, key, value)

  defp canonical_min_score(value) when is_number(value), do: %{"default" => value / 1}

  defp canonical_min_score(value) when is_map(value) do
    value
    |> stringify_shallow()
    |> Map.new(fn {label, score} -> {label, coerce_float(score)} end)
  end

  defp canonical_min_score(value), do: value

  # A present-but-empty tier excludes every label, which no form's "no
  # rows" can mean — it is dropped, so it reads as the absent block.
  defp canonical_tier(value) when is_map(value) do
    tier =
      value
      |> stringify_shallow()
      |> Map.new(fn {label, rule} -> {label, canonical_tier_rule(rule)} end)

    if map_size(tier) == 0, do: nil, else: tier
  end

  defp canonical_tier(value), do: value

  defp canonical_tier_rule(rule) when is_number(rule), do: %{"min_score" => rule / 1}

  defp canonical_tier_rule(rule) when is_map(rule) do
    rule
    |> stringify_shallow()
    |> Map.new(fn
      {"min_score", score} when is_number(score) -> {"min_score", score / 1}
      pair -> pair
    end)
  end

  defp canonical_tier_rule(rule), do: rule

  defp canonical_extra_args(value) when is_binary(value), do: String.split(value)
  defp canonical_extra_args(value), do: value

  defp canonical_motion_json(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> Jason.encode!(decoded)
      {:error, _reason} -> value
    end
  end

  defp canonical_motion_json(value), do: value

  defp canonical_retention(value) when is_map(value) do
    value = stringify_shallow(value)

    %{}
    |> put_present(value, "days")
    |> put_per_label(value)
    |> then(fn retention -> if map_size(retention) == 0, do: nil, else: retention end)
  end

  defp canonical_retention(value), do: value

  defp put_present(acc, source, key) do
    case Map.get(source, key) do
      nil -> acc
      val -> Map.put(acc, key, val)
    end
  end

  defp put_per_label(acc, source) do
    case Map.get(source, "per_label") do
      nil ->
        acc

      per_label when is_map(per_label) ->
        stringified =
          per_label
          |> stringify_shallow()
          |> Enum.reject(fn {_label, val} -> is_nil(val) end)
          |> Map.new()

        if map_size(stringified) == 0, do: acc, else: Map.put(acc, "per_label", stringified)

      other ->
        Map.put(acc, "per_label", other)
    end
  end

  defp coerce_float(value) when is_number(value), do: value / 1
  defp coerce_float(value), do: value

  defp stringify_shallow(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
end
