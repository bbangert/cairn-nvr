defmodule Driver.CLI do
  @moduledoc """
  Entry point; stage arguments identical to the bash driver's:

      mix run -e 'Driver.CLI.main(System.argv())' -- [all|push|envcheck|content|latency|fetch|finish]

  No argument means `all`, as in bash. Like bash's `trap do_finish EXIT`,
  any run that includes envcheck/content/latency ends with the finish
  stage — success or failure — so an aborted campaign never leaves the
  NVR down, the governor pinned, or distribution enabled.
  """

  require Logger

  alias Driver.Campaign
  alias Driver.Campaign.Config

  @spec main([String.t()]) :: no_return()
  def main(argv) do
    case parse(argv) do
      {:ok, stages} ->
        case run(stages, Config.new()) do
          :ok ->
            System.halt(0)

          {:error, reason} ->
            Logger.error("campaign failed: #{inspect(reason)}")
            Logger.flush()
            System.halt(1)
        end

      {:error, message} ->
        raise ArgumentError, message
    end
  end

  @doc "Resolve argv to the stage list to run, preserving campaign order."
  @spec parse([String.t()]) :: {:ok, [atom()]} | {:error, String.t()}
  def parse([]), do: {:ok, Campaign.stages()}
  def parse(["all"]), do: {:ok, Campaign.stages()}

  def parse([arg]) do
    stages = Campaign.stages()

    case Enum.find(stages, &(Atom.to_string(&1) == arg)) do
      nil -> {:error, usage(arg)}
      stage -> {:ok, [stage]}
    end
  end

  def parse(argv), do: {:error, usage(Enum.join(argv, " "))}

  @doc "Run stages in order on one session; the finish trap when due."
  @spec run([atom()], Config.t()) :: :ok | {:error, term()}
  def run(stages, cfg) do
    with {:ok, board} <- cfg.board.connect(cfg.host, ssh: cfg.ssh) do
      case run_stages(stages, board, cfg) do
        {:ok, _board, _finish_ran = true} ->
          :ok

        {:ok, board, false} ->
          if needs_finish?(stages), do: run_finish(board, cfg), else: :ok

        {:error, reason, board} ->
          if needs_finish?(stages) do
            case run_finish(board, cfg) do
              :ok -> {:error, reason}
              {:error, finish_reason} -> {:error, {reason, {:finish_also_failed, finish_reason}}}
            end
          else
            {:error, reason}
          end
      end
    end
  end

  defp run_stages(stages, board, cfg) do
    Enum.reduce_while(stages, {:ok, board, false}, fn stage, {:ok, b, _} ->
      with {:ok, b} <- cfg.board.ensure_session(b),
           {:ok, b} <- Campaign.run(stage, b, cfg) do
        Campaign.log(cfg, "stage #{stage} done")
        {:cont, {:ok, b, stage == :finish}}
      else
        {:error, reason} -> {:halt, {:error, {stage, reason}, b}}
      end
    end)
  end

  defp run_finish(board, cfg) do
    with {:ok, board} <- cfg.board.ensure_session(board),
         {:ok, _board} <- Campaign.run(:finish, board, cfg) do
      Campaign.log(cfg, "stage finish done")
      :ok
    else
      {:error, reason} -> {:error, {:finish, reason}}
    end
  end

  defp needs_finish?(stages), do: Enum.any?(stages, &(&1 in [:envcheck, :content, :latency]))

  defp usage(got) do
    "unknown stage #{inspect(got)} — usage: driver [all|" <>
      Enum.map_join(Campaign.stages(), "|", &Atom.to_string/1) <> "]"
  end
end
