defmodule Cairn.Rockchip.MixProject do
  use Mix.Project

  def project do
    [
      app: :cairn_rockchip,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger]]

  # Only `cairn_stage` (and, in Rust, `cairn-detect`), never the base app:
  # that is what keeps this library extractable.
  defp deps do
    [
      {:cairn_stage, path: "../../libs/cairn_stage"}
    ]
  end
end
