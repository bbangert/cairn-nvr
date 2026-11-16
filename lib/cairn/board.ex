defmodule Cairn.Board do
  @moduledoc """
  The `Cairn.Stage.Board` this release was built with: `CAIRN_BOARD` picks the
  `config/boards/` file that names it. The base reads it here and nowhere else.
  """

  @board Application.compile_env(:cairn, :board, Cairn.Board.Generic)

  @spec module() :: module()
  def module, do: @board
end
