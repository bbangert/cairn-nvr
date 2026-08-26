defmodule Driver.CLI do
  @moduledoc """
  Entry point; stage arguments identical to the bash driver's:

      mix run -e 'Driver.CLI.main(System.argv())' -- [all|push|envcheck|content|latency|fetch|finish]

  No argument means `all`, as in bash.
  """

  @spec main([String.t()]) :: no_return()
  def main(argv) do
    case parse(argv) do
      {:ok, _stages} -> raise "P2: stage execution not wired yet"
      {:error, message} -> raise ArgumentError, message
    end
  end

  @doc "Resolve argv to the stage list to run, preserving campaign order."
  @spec parse([String.t()]) :: {:ok, [atom()]} | {:error, String.t()}
  def parse([]), do: {:ok, Driver.Campaign.stages()}
  def parse(["all"]), do: {:ok, Driver.Campaign.stages()}

  def parse([arg]) do
    stages = Driver.Campaign.stages()

    case Enum.find(stages, &(Atom.to_string(&1) == arg)) do
      nil -> {:error, usage(arg)}
      stage -> {:ok, [stage]}
    end
  end

  def parse(argv), do: {:error, usage(Enum.join(argv, " "))}

  defp usage(got) do
    "unknown stage #{inspect(got)} — usage: driver [all|" <>
      Enum.map_join(Driver.Campaign.stages(), "|", &Atom.to_string/1) <> "]"
  end
end
