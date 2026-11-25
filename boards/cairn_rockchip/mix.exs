defmodule Cairn.Rockchip.MixProject do
  use Mix.Project

  def project do
    [
      app: :cairn_rockchip,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      cairn_board: Cairn.Rockchip.Board,
      deps: deps(),
      # As the base's: a path dependency in the PLT goes stale, so
      # `cairn_stage` is analysed as project code. `:mix` for its board task.
      dialyzer: [
        plt_add_apps: [:mix],
        plt_ignore_apps: [:cairn_stage],
        paths: Enum.map([:cairn_rockchip, :cairn_stage], &"_build/#{Mix.env()}/lib/#{&1}/ebin"),
        plt_core_path: "priv/plts",
        plt_local_path: "priv/plts"
      ]
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
      {:membrane_h264_format, "~> 0.6.1"},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
