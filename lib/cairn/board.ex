defmodule Cairn.Board do
  @moduledoc """
  The `Cairn.Stage.Board` this node runs: the one `Cairn.Board.Loader`
  attached from `CAIRN_BOARD_DIR`, else `Cairn.Board.Generic`. The base reads
  it here and nowhere else.
  """

  alias Cairn.Board.Loader

  @doc """
  Raises while `CAIRN_BOARD_DIR` names a board that failed to attach: the
  operator asked for that board, and answering with the generic one would
  run, or measure, the wrong hardware without saying so. A booted node never
  gets here, since `:cairn` refuses to start on the same failure.
  """
  @spec module() :: module()
  def module do
    case Loader.board() do
      {:ok, board} -> board
      :none -> Cairn.Board.Generic
      {:error, message} -> raise "CAIRN_BOARD_DIR: #{message}"
    end
  end

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
