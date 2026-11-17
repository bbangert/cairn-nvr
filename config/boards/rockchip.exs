import Config

config :cairn, board: Cairn.Rockchip.Board

# The base's own libraries, lent to the board: a board library depends only on
# `cairn_stage` and cannot name them (D-G1).
config :cairn_rockchip,
  generic: [decoder: Cairn.Native, engine: %{module: CairnOrt, canary: "cairn-detect"}]
