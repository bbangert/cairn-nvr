defmodule Cairn.Cameras.Candidate do
  @moduledoc """
  A camera row nobody has written yet, judged against the fleet it would join.

  The candidate is rendered into the fleet in place of the row with its id, or
  appended when there is none — a disabled camera's row is not among the
  rendered rows, and its candidate is validated anyway so its own field errors
  reach the operator. The whole map then goes through `Cairn.Config.from_map/1`,
  the same validator a load runs, and the errors come back classified by who
  can fix them.

  Functions over data: rows, globals and settings arrive as arguments, no
  process is called and no row is read. Not pure in the wider sense — the
  validator reads profile files, model artifacts and `CAIRN_DATA_DIR`.
  """

  alias Cairn.Config

  @typedoc "A camera as `Cairn.Config.from_map/1` reads it, keyed by strings."
  @type row :: map()

  @typedoc """
  `errors` is the validator's whole list, in its order, for routing to fields;
  the other keys partition it. `own` blocks the save (a row the loader would
  skip is the one thing this save must not write); `others` cannot be fixed
  from this form and `Cairn.Config.Server.update/3` skips those rows anyway;
  `fleet` is everything `Cairn.Config.partition_by_camera/1` could not pin on
  a camera, of which `preexisting_fleet` is the part that is true without the
  candidate.
  """
  @type result :: %{
          errors: [String.t()],
          own: [String.t()],
          others: %{String.t() => [String.t()]},
          fleet: [String.t()],
          preexisting_fleet: [String.t()],
          warnings: [String.t()]
        }

  @doc """
  Validates `candidate` among `rows` (the fleet as a load would render it)
  under `globals` (the config map's non-camera half). `opts` reach
  `Cairn.Config.from_map/2` unchanged, on both passes.
  """
  @spec validate(row(), [row()], map(), keyword()) :: result()
  def validate(candidate, rows, globals, opts \\ []) do
    id = Map.get(candidate, "id")

    case Config.from_map(Map.put(globals, "cameras", fleet(candidate, rows, id)), opts) do
      {:ok, _config, warnings} ->
        %{errors: [], own: [], others: %{}, fleet: [], preexisting_fleet: [], warnings: warnings}

      {:error, errors} ->
        {per_camera, fleet_errors} = Config.partition_by_camera(errors)

        %{
          errors: errors,
          own: Map.get(per_camera, id, []),
          others: Map.delete(per_camera, id),
          fleet: fleet_errors,
          preexisting_fleet: preexisting_fleet(fleet_errors, rows, globals, id, opts),
          warnings: []
        }
    end
  end

  @doc "One row rendered as the validator reads it — `Cairn.Cameras.render_row/1`."
  @spec render_row(%{id: String.t(), settings: map(), zones: [map()]}) :: row()
  defdelegate render_row(row), to: Cairn.Cameras

  @doc """
  Whether saving `new` over `saved` restarts the camera's tree: a field baked
  into a subprocess or a child spec at tree birth moved. `restart_fields` is
  the caller's set (`Cairn.Config.Server.restart_fields/0` plus the fields the
  form resolves above the camera), as atoms or strings.

  Settings-level and so a prediction, not the diff: the resolved comparisons
  `Cairn.Config.Server.diff_cameras/2` makes can restart a camera whose own
  settings did not move. A camera with no saved row is being added, not
  restarted.
  """
  @spec would_restart?(map() | nil, map(), [atom() | String.t()]) :: boolean()
  def would_restart?(nil, _new, _restart_fields), do: false

  def would_restart?(saved, new, restart_fields) do
    fields = Enum.map(restart_fields, &to_string/1)
    Map.take(saved, fields) != Map.take(new, fields)
  end

  defp fleet(candidate, rows, id) do
    if Enum.any?(rows, &(Map.get(&1, "id") == id)),
      do: Enum.map(rows, &replace(&1, candidate, id)),
      else: rows ++ [candidate]
  end

  defp replace(row, candidate, id), do: if(Map.get(row, "id") == id, do: candidate, else: row)

  # The fleet-level messages the fleet already had with this row left out
  # entirely — nothing stands in for it, so a rule the candidate alone trips
  # cannot appear. A fault in the globals themselves (bad retention, a broken
  # plugin config) files as fleet-level the same as a cross-camera rule, and
  # surviving the row's removal is what tells the two apart: the caller can
  # excuse the second for a camera that is disabled (it will not bind until
  # the toggle flips, and the load re-checks it then) but never the first.
  #
  # Compared against `fleet_errors` from the same pass, so an equal message is
  # the same rule failing for the same reason.
  defp preexisting_fleet([], _rows, _globals, _id, _opts), do: []

  defp preexisting_fleet(fleet_errors, rows, globals, id, opts) do
    baseline = Enum.reject(rows, &(Map.get(&1, "id") == id))

    case Config.from_map(Map.put(globals, "cameras", baseline), opts) do
      {:error, errors} ->
        {_per_camera, baseline_fleet} = Config.partition_by_camera(errors)
        Enum.filter(fleet_errors, &(&1 in baseline_fleet))

      {:ok, _config, _warnings} ->
        []
    end
  end
end
