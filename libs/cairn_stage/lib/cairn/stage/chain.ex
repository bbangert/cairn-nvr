defmodule Cairn.Stage.Chain do
  @moduledoc """
  Checks a board's detect chain before anything is built from it: each
  stage covered at most once and in `Cairn.Stage.all/0` order, the required
  ones all covered, and the formats meeting end to end from `:h264` to
  `:detections`.
  """

  alias Cairn.Stage
  alias Cairn.Stage.Step

  @doc """
  The stages a camera's chain must cover. `:motion` only when the camera
  configured a gate: a board that drops it would detect on every frame the
  operator asked to skip.
  """
  @spec required(boolean()) :: [Stage.t()]
  def required(true), do: Stage.all()
  def required(false), do: Stage.all() -- [:motion]

  @spec validate([Step.t()], [Stage.t()]) :: :ok | {:error, String.t()}
  def validate([_ | _] = steps, required) do
    if Enum.all?(steps, &is_struct(&1, Step)) do
      with :ok <- unique_names(steps),
           {:ok, covered} <- coverage(steps),
           :ok <- all_covered(steps, covered, required) do
        formats(steps)
      end
    else
      {:error, "every step must be a %Cairn.Stage.Step{}, got #{inspect(steps)}"}
    end
  end

  def validate(steps, _required),
    do: {:error, "a chain is a non-empty list of steps, got #{inspect(steps)}"}

  defp unique_names(steps) do
    case steps |> Enum.frequencies_by(& &1.name) |> Enum.find(fn {_, n} -> n > 1 end) do
      nil -> :ok
      {name, _} -> {:error, "step #{inspect(name)} appears more than once"}
    end
  end

  # Walks the steps carrying which step covered each stage so far, so a repeat
  # and a stage out of order are each named at the step that commits them.
  defp coverage(steps) do
    Enum.reduce_while(steps, {:ok, %{}}, fn step, {:ok, seen} ->
      case Enum.reduce_while(step.covers, {:ok, seen}, &cover(step, &1, &2)) do
        {:ok, seen} -> {:cont, {:ok, seen}}
        error -> {:halt, error}
      end
    end)
  end

  defp cover(step, stage, {:ok, seen}) do
    cond do
      stage not in Stage.all() ->
        {:halt, {:error, "step #{inspect(step.name)} covers #{inspect(stage)}, not a stage"}}

      Map.has_key?(seen, stage) ->
        {:halt,
         {:error,
          "step #{inspect(step.name)} covers #{inspect(stage)}, " <>
            "already covered by #{inspect(seen[stage])}"}}

      later = Enum.find(Map.keys(seen), &(index(&1) > index(stage))) ->
        {:halt,
         {:error,
          "step #{inspect(step.name)} covers #{inspect(stage)} after " <>
            "#{inspect(seen[later])} covered #{inspect(later)}"}}

      true ->
        {:cont, {:ok, Map.put(seen, stage, step.name)}}
    end
  end

  defp index(stage), do: Enum.find_index(Stage.all(), &(&1 == stage))

  defp all_covered(steps, covered, required) do
    case Enum.reject(required, &Map.has_key?(covered, &1)) do
      [] ->
        :ok

      missing ->
        {:error,
         "no step covers #{Enum.map_join(missing, ", ", &inspect/1)} " <>
           "(steps: #{Enum.map_join(steps, ", ", &inspect(&1.name))})"}
    end
  end

  defp formats([first | _] = steps) do
    last = List.last(steps)

    cond do
      first.input != :h264 ->
        {:error, "step #{inspect(first.name)} takes #{inspect(first.input)}, not :h264"}

      last.output != :detections ->
        {:error, "step #{inspect(last.name)} emits #{inspect(last.output)}, not :detections"}

      true ->
        adjacent(steps)
    end
  end

  defp adjacent(steps) do
    steps
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value(:ok, fn
      [%{output: format}, %{input: format}] ->
        nil

      [from, to] ->
        {:error,
         "step #{inspect(from.name)} emits #{inspect(from.output)} but " <>
           "#{inspect(to.name)} takes #{inspect(to.input)}"}
    end)
  end
end
