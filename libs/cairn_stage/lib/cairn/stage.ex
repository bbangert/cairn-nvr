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

  @doc """
  The version of what a board built apart from this base must agree with.
  `cairn-ort`'s `CONTRACT` mirrors it, and an engine NIF reports the one it
  was built against from `contract/0`.

  Bump it for a change an existing board would break on: a non-optional
  callback added to or changed on `Cairn.Stage.Board` or a NIF behaviour; a
  context or capability key removed or re-typed; a step rule; the shape of a
  frame, of frame metadata or of `Cairn.Stage.DmaFrame`.
  """
  @spec contract() :: pos_integer()
  def contract, do: 1
end
