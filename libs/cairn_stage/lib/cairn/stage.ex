defmodule Cairn.Stage do
  @moduledoc """
  The stages every detect chain covers, in the order frames pass them.

  A board composes its chain from elements that each cover some of these
  (`Cairn.Stage.Step`); `Cairn.Stage.Chain` checks the composition.
  """

  @stages [:decode, :scale, :motion, :infer]

  @type t :: :decode | :scale | :motion | :infer

  @spec all() :: [t()]
  def all, do: @stages
end
