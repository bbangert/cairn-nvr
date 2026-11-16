defmodule CairnStage.MixProject do
  use Mix.Project

  def project do
    [
      app: :cairn_stage,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger]]

  # The base's own requirements, so a board built against this library
  # resolves the same membrane the base does.
  defp deps do
    [
      {:membrane_core, "~> 1.3.4"},
      {:membrane_raw_video_format, "~> 0.4.1"}
    ]
  end
end
