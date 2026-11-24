defmodule Mix.Tasks.CairnStage.Board do
  @shortdoc "Writes this board project's board directory"
  @moduledoc """
  Writes the board directory of the board application this Mix project
  builds, checked against the core release it will attach to:

      mix cairn_stage.board --core-rel <release>/releases/<vsn>/cairn.rel --out <dir>

  The project names its board module in `project/0` as `cairn_board:`.
  Run it in the environment the board ships from, after the project
  compiled. `Cairn.Stage.BoardDir` has the rules.
  """

  use Mix.Task

  alias Cairn.Stage.BoardDir

  @impl Mix.Task
  def run(args) do
    {rel, out} = parse(args)
    config = Mix.Project.config()
    app = Keyword.fetch!(config, :app)

    board =
      config[:cairn_board] ||
        Mix.raise("add the board module to project/0 in mix.exs: cairn_board: My.Board")

    opts = [
      lib_dir: Path.join(Mix.Project.build_path(), "lib"),
      app: app,
      board: board,
      contract: Cairn.Stage.contract(),
      rel: Path.expand(rel),
      out: Path.expand(out)
    ]

    case BoardDir.write(opts) do
      :ok ->
        apps = opts[:out] |> Path.join("lib") |> File.ls!() |> Enum.sort()

        Mix.shell().info(
          "#{opts[:out]}: board #{inspect(board)}, contract #{opts[:contract]}, " <>
            "lib #{Enum.join(apps, " ")}"
        )

      {:error, errors} ->
        Mix.raise("no board directory written:\n" <> Enum.map_join(errors, "\n", &("  " <> &1)))
    end
  end

  defp parse(args) do
    case OptionParser.parse(args, strict: [core_rel: :string, out: :string]) do
      {opts, [], []} ->
        # An empty `--out` would expand to the working directory.
        with {:ok, rel} when rel != "" <- Keyword.fetch(opts, :core_rel),
             {:ok, out} when out != "" <- Keyword.fetch(opts, :out) do
          {rel, out}
        else
          _ -> usage()
        end

      _ ->
        usage()
    end
  end

  @spec usage() :: no_return()
  defp usage, do: Mix.raise("usage: mix cairn_stage.board --core-rel <cairn.rel> --out <dir>")
end
