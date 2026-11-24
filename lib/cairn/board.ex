defmodule Cairn.Board do
  @moduledoc """
  The `Cairn.Stage.Board` this release was built with: `CAIRN_BOARD` picks the
  `config/boards/` file that names it. The base reads it here and nowhere else.
  """

  @board Application.compile_env(:cairn, :board, Cairn.Board.Generic)

  @spec module() :: module()
  def module, do: @board

  @doc """
  The libraries the base lends its board (`t:Cairn.Stage.Board.base/0`).
  `Cairn.Board.Generic` answers from it too, rather than naming them again.
  """
  @spec base() :: Cairn.Stage.Board.base()
  def base do
    %{
      decoder: Cairn.Native,
      host: Cairn.Native.Host,
      engine: %{module: CairnOrt, canary: "cairn-detect"}
    }
  end
end
