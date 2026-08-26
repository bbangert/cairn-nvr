defmodule Driver.Campaign do
  @moduledoc """
  Campaign stages, one function per bash-driver stage, same evidence
  layout under `out-*/htp/`. Board-side methodology stays in the pushed
  `sh` scripts (their sha IS the methodology digest); the retry guard
  keeps shelling out to `campaign_meta.py` locally.
  """

  @stages ~w(push envcheck content latency fetch finish)a

  @doc "Stage names in campaign order (`all` runs the lot)."
  @spec stages() :: [atom()]
  def stages, do: @stages

  @spec run(atom(), Driver.Board.t(), keyword()) :: :ok | {:error, term()}
  def run(stage, board, opts \\ [])
  def run(:push, _board, _opts), do: raise("P2-T1")
  def run(:envcheck, _board, _opts), do: raise("P2-T2")
  def run(:content, _board, _opts), do: raise("P2-T3")
  def run(:latency, _board, _opts), do: raise("P2-T3")
  def run(:fetch, _board, _opts), do: raise("P2-T3")
  def run(:finish, _board, _opts), do: raise("P2-T4")
end
