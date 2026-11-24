defmodule Cairn.Stage.Capabilities do
  @moduledoc """
  The optional keys of `t:Cairn.Stage.Board.capabilities/0`, read with their
  defaults. Every reader goes through here so a board that omits a key gets
  the same answer everywhere.

  Total over a malformed map: a raise here would crash every config load, so
  a value outside the type reads as the cautious answer.
  """

  alias Cairn.Stage.Board

  @unlisted {:unproven, "not listed by the board"}

  @doc """
  Whether a group needs both acknowledgements to run this backend. Only an
  explicit `false` says no: a board that forgets the key, or sets it to
  something else, must not have its backend run unacknowledged.
  """
  @spec experimental?(map()) :: boolean()
  def experimental?(capabilities), do: Map.get(capabilities, :experimental) !== false

  @doc """
  Whether `contract`'s converted model was measured to detect on this
  backend. A backend without `conversions` declares no verdicts, so every
  contract passes; with it, a contract the board does not list, or lists
  with no verdict of the right shape, is unproven.
  """
  @spec conversion(map(), String.t()) :: Board.conversion()
  def conversion(capabilities, contract) do
    case Map.fetch(capabilities, :conversions) do
      :error -> :proven
      {:ok, %{contracts: %{} = contracts}} -> verdict(Map.get(contracts, contract))
      {:ok, _no_contracts} -> @unlisted
    end
  end

  defp verdict(:proven), do: :proven
  defp verdict({:unproven, why} = verdict) when is_binary(why), do: verdict
  defp verdict(_unlisted_or_malformed), do: @unlisted

  @doc "Where the backend's conversion measurements are, `nil` when the board names none."
  @spec evidence(map()) :: String.t() | nil
  def evidence(capabilities) do
    case Map.get(capabilities, :conversions) do
      %{evidence: evidence} when is_binary(evidence) -> evidence
      _none -> nil
    end
  end
end
