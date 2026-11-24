defmodule CairnFixtureBoard.MixProject do
  use Mix.Project

  # Core's deps and lock, so the fixture builds against the versions the
  # release ships, and nothing it fetches or builds lands under `test/`,
  # where core's `mix test`, format and credo would read it.
  def project do
    [
      app: :cairn_fixture_board,
      version: "0.1.0",
      elixir: "~> 1.19",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      build_path: "../../_build/fixture_board",
      deps: [{:cairn_stage, path: "../../libs/cairn_stage"}]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
