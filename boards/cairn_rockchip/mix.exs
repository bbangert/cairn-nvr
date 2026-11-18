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

  # Only `cairn_stage`, never the base app: that is what keeps this library
  # extractable. Its Rust crate has two path dependencies into this
  # repository, `cairn-detect` and `cairn-ort` (the engine hosting, with its
  # own NIF entry off).
  defp deps do
    [
      {:cairn_stage, path: "../../libs/cairn_stage"},
      {:membrane_h264_format, "~> 0.6.1"}
    ]
  end
end
