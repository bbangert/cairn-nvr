defmodule CairnFixtureBoard.MixProject do
  use Mix.Project

  # Core's deps and lock, so the fixture builds against the versions the
  # release ships, and its deps and build land outside `test/`, where core's
  # `mix test`, format and credo would read them. Only the stub NIF is
  # copied in, to `priv/native`, the `priv` `mix cairn_stage.board` ships.
  def project do
    [
      app: :cairn_fixture_board,
      version: "0.1.0",
      elixir: "~> 1.19",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      build_path: "../../_build/fixture_board",
      cairn_board: Cairn.FixtureBoard.Board,
      deps: [{:cairn_stage, path: "../../libs/cairn_stage"}]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
