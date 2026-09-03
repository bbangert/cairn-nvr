defmodule Cairn.Cameras.Candidate do
  @moduledoc """
  A camera row nobody has written yet, judged against the fleet it would join.

  An edit is rendered into the fleet in place of the row with its id, or
  appended when there is none — a disabled camera's row is not among the
  rendered rows, and its candidate is validated anyway so its own field errors
  reach the operator. A create is always appended, even onto a fleet that
  already has its id: replacing that row would hand the validator one camera
  where the save would make two, and the duplicate id nobody may write would
  never be reported. The whole map then goes through `Cairn.Config.from_map/1`,
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
  Which save the candidate is for. `:edit` replaces the row with its id (and
  appends when the fleet has none, the disabled case); `:create` appends
  unconditionally, so a taken id reaches `Cairn.Config`'s duplicate-id rule.
  Required, and with no default: the two differ only on the case that matters,
  and a caller that guessed wrong gets silence rather than an error.
  """
  @type mode :: :create | :edit

  @typedoc """
  `errors` is the validator's whole list, in its order, for routing to fields;
  the other keys partition it. `own` blocks the save (a row the loader would
  skip is the one thing this save must not write); `others` cannot be fixed
  from this form and `Cairn.Config.Server.update/3` skips those rows anyway;
  `fleet` is everything `Cairn.Config.partition_by_camera/1` could not pin on
  a camera, of which `preexisting_fleet` is the part already true of `rows`
  before the candidate was applied to them.
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
  under `globals` (the config map's non-camera half). `mode:` is required
  (`t:mode/0`); the rest of `opts` reach `Cairn.Config.from_map/2` unchanged,
  on both passes.
  """
  @spec validate(row(), [row()], map(), keyword()) :: result()
  def validate(candidate, rows, globals, opts) do
    {mode, opts} = pop_mode(opts)
    id = Map.get(candidate, "id")

    case Config.from_map(Map.put(globals, "cameras", fleet(candidate, rows, id, mode)), opts) do
      {:ok, _config, warnings} ->
        %{errors: [], own: [], others: %{}, fleet: [], preexisting_fleet: [], warnings: warnings}

      {:error, errors} ->
        {per_camera, fleet_errors} = Config.partition_by_camera(errors)
        {own_unnamed, fleet_errors} = claim_unnamed(fleet_errors, mode, rows, id)

        %{
          errors: errors,
          own: Map.get(per_camera, id, []) ++ own_unnamed,
          others: Map.delete(per_camera, id),
          fleet: fleet_errors,
          preexisting_fleet: preexisting_fleet(fleet_errors, rows, globals, opts),
          warnings: []
        }
    end
  end

  # On `:create`, `fleet/4` appends the candidate last, so a candidate whose
  # id fails `Cairn.Config.Camera`'s check cannot even name itself and comes
  # back index-prefixed (`camera ##{length(rows)}: id is required …`) —
  # `Config.partition_by_camera/1` has no id to key it on and files it
  # fleet-level. Rewriting that index onto the candidate's own id (blank or
  # malformed alike, both render as `""`) reclaims it as `own`;
  # `Cairn.Cameras.Settings.field_errors/3` recognizes the same literal
  # prefix for the id it cannot validate either, and routes it to the `id`
  # field. An edit's candidate always occupies a real position (its own row
  # or an append), so it never produces an index-prefixed message.
  defp claim_unnamed(fleet_errors, :create, rows, id) do
    index_prefix = "camera ##{length(rows)}: "
    {mine, rest} = Enum.split_with(fleet_errors, &String.starts_with?(&1, index_prefix))
    literal_prefix = "camera #{id}: "
    {Enum.map(mine, &String.replace_prefix(&1, index_prefix, literal_prefix)), rest}
  end

  defp claim_unnamed(fleet_errors, :edit, _rows, _id), do: {[], fleet_errors}

  @doc "One row rendered as the validator reads it — `Cairn.Cameras.render_row/1`."
  @spec render_row(%{id: String.t(), settings: map(), zones: [map()]}) :: row()
  defdelegate render_row(row), to: Cairn.Cameras

  defp pop_mode(opts) do
    case Keyword.pop(opts, :mode) do
      {mode, rest} when mode in [:create, :edit] ->
        {mode, rest}

      {other, _rest} ->
        raise ArgumentError,
              "Cairn.Cameras.Candidate.validate/4 needs mode: :create | :edit, got: " <>
                inspect(other)
    end
  end

  defp fleet(candidate, rows, _id, :create), do: rows ++ [candidate]

  defp fleet(candidate, rows, id, :edit) do
    if Enum.any?(rows, &(Map.get(&1, "id") == id)),
      do: Enum.map(rows, &replace(&1, candidate, id)),
      else: rows ++ [candidate]
  end

  defp replace(row, candidate, id), do: if(Map.get(row, "id") == id, do: candidate, else: row)

  # The fleet-level messages the fleet already had before this edit: `rows` as
  # given, the saved row still in it and unchanged. Dropping the row instead
  # made every fault it was already party to (a model mismatch against another
  # camera, say) look newly introduced by an edit that touched neither side. A
  # new or disabled candidate is simply not in `rows` to begin with, so the
  # baseline is the fleet without it either way.
  #
  # A fault in the globals themselves (bad retention, a broken plugin config)
  # files as fleet-level the same as a cross-camera rule, and surviving this
  # pass is what tells "already broken" from "this edit broke it": the caller
  # can excuse the first for a camera that is disabled (it will not bind until
  # the toggle flips, and the load re-checks it then) but never the second.
  #
  # Compared against `fleet_errors` from the same pass, so an equal message is
  # the same rule failing for the same reason.
  defp preexisting_fleet([], _rows, _globals, _opts), do: []

  defp preexisting_fleet(fleet_errors, rows, globals, opts) do
    case Config.from_map(Map.put(globals, "cameras", rows), opts) do
      {:error, errors} ->
        {_per_camera, baseline_fleet} = Config.partition_by_camera(errors)
        Enum.filter(fleet_errors, &(&1 in baseline_fleet))

      {:ok, _config, _warnings} ->
        []
    end
  end
end
