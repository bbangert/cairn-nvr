defmodule Cairn.Stage.Capabilities do
  @moduledoc """
  The optional keys of `t:Cairn.Stage.Board.capabilities/0`, read with their
  defaults. Every reader goes through here so a board that omits a key gets
  the same answer everywhere.
  """

  alias Cairn.Stage.Board

  @unlisted {:unproven, "not listed by the board"}

  # Absent is experimental: a board that forgets the key must not have its
  # backend run without the operator's acknowledgement.
  @spec experimental?(map()) :: boolean()
  def experimental?(capabilities), do: Map.get(capabilities, :experimental, true)

  @doc """
  Whether `contract`'s converted model was measured to detect on this
  backend. `:proven` for a backend with no conversion step; with one, a
  contract the board does not list is unproven.
  """
  @spec conversion(map(), String.t()) :: Board.conversion()
  def conversion(capabilities, contract) do
    case Map.fetch(capabilities, :conversions) do
      {:ok, %{contracts: contracts}} -> Map.get(contracts, contract, @unlisted)
      :error -> :proven
    end
  end

  @doc "Where the backend's conversion measurements are, `nil` with no conversion step."
  @spec evidence(map()) :: String.t() | nil
  def evidence(capabilities), do: get_in(capabilities, [:conversions, :evidence])
end
