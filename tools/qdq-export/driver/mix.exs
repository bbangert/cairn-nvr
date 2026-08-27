defmodule Driver.MixProject do
  use Mix.Project

  def project do
    [
      app: :driver,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Zero deps is deliberate: the driver must run anywhere the repo checks
  # out, stdlib + distribution only.
  defp deps do
    []
  end
end
