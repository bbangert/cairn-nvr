defmodule Cairn.Board do
  @moduledoc """
  The `Cairn.Stage.Board` this node runs: the one `Cairn.Board.Loader`
  attached from `CAIRN_BOARD_DIR`, else the one this release was built with
  (`CAIRN_BOARD` picks the `config/boards/` file that names it). The base
  reads it here and nowhere else.
  """

  alias Cairn.Board.Loader

  @default Application.compile_env(:cairn, :board, Cairn.Board.Generic)

  @doc """
  Raises while `CAIRN_BOARD_DIR` names a board that failed to attach: the
  operator asked for that board, and answering with the built-in one would
  run, or measure, the wrong hardware without saying so. A booted node never
  gets here, since `:cairn` refuses to start on the same failure.
  """
  @spec module() :: module()
  def module do
    case Loader.board() do
      {:ok, board} -> board
      :none -> @default
      {:error, message} -> raise "CAIRN_BOARD_DIR: #{message}"
    end
  end
end
