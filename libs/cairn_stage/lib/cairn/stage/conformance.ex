defmodule Cairn.Stage.Conformance do
  @moduledoc """
  Whether a board module keeps the contract, checked before the base runs
  any of it: every callback exported, every capability map of the documented
  shape, every step's element loaded and a Membrane element or bin, every
  library a backend or decoder names loaded and exporting its behaviour, and
  `profiles_dir/0` a directory. An engine library that loaded must report
  the expected contract number and `Cairn.Stage.EngineNif.frame_meta_keys/0`.

  Plain functions, so the base's loader and a board's own suite run the same
  check. It does not validate a chain (`Cairn.Stage.Chain`): that needs the
  base's own steps and a camera's gate, and the base checks each camera's
  chain as it builds it.
  """

  alias Cairn.Stage
  alias Cairn.Stage.{Board, Capabilities, DecoderNif, EngineNif, Step}

  @doc """
  `:ok`, or every violation found, each naming what it is about.

  Options: `:contract`, the number engine libraries must report (default
  `Cairn.Stage.contract/0`); `:generic`, the steps handed to
  `detect_chain/1` as the context's `generic` (default none, so only the
  board's own steps are checked).
  """
  @spec check(module(), keyword()) :: :ok | {:error, [String.t()]}
  def check(board, opts \\ []) do
    contract = Keyword.get(opts, :contract, Stage.contract())
    generic = Keyword.get(opts, :generic, [])

    violations =
      with :ok <- loaded(board, "board module"),
           [] <- missing(board, Board) do
        name(board) ++
          backends(board, contract) ++
          decoders(board, generic) ++ profiles_dir(board)
      else
        {:error, violation} -> [violation]
        missing -> ["board module #{inspect(board)} does not export #{Enum.join(missing, ", ")}"]
      end

    if violations == [], do: :ok, else: {:error, violations}
  end

  # `Code.ensure_loaded/1` loads in an interactive VM and answers
  # `{:error, :embedded}` in an embedded one for a module nothing loaded,
  # which is the case Membrane's element check fails silently on.
  defp loaded(module, what) when is_atom(module) do
    case Code.ensure_loaded(module) do
      {:module, ^module} -> :ok
      {:error, reason} -> {:error, "#{what} #{inspect(module)} is not loaded (#{reason})"}
    end
  end

  defp loaded(other, what), do: {:error, "#{what} #{inspect(other)} is not a module"}

  defp missing(module, behaviour) do
    required =
      behaviour.behaviour_info(:callbacks) -- behaviour.behaviour_info(:optional_callbacks)

    for {fun, arity} <- Enum.sort(required),
        not function_exported?(module, fun, arity),
        do: "#{fun}/#{arity}"
  end

  defp name(board) do
    judge(board, :name, [], fn
      name when is_binary(name) and name != "" -> []
      other -> ["#{inspect(board)}.name/0 is #{inspect(other)}, not a non-empty string"]
    end)
  end

  defp backends(board, contract) do
    judge(board, :backends, [], fn
      backends when is_map(backends) and map_size(backends) > 0 ->
        Enum.flat_map(Enum.sort(backends), fn {backend, caps} ->
          capabilities(board, backend, caps) ++ engine(board, backend, contract)
        end)

      other ->
        ["#{inspect(board)}.backends/0 is #{inspect(other)}, not a non-empty map"]
    end)
  end

  @required [
    artifact: &is_binary/1,
    fused_nms: &is_boolean/1,
    dynamic_shapes: &is_boolean/1,
    cpu_twin: &is_boolean/1
  ]

  # The optional keys are read through `Capabilities`, which is total: a
  # malformed value there reads as the cautious answer without a word, so a
  # value it would not read back as written is the board's mistake to hear
  # about here.
  defp capabilities(board, backend, caps) when is_binary(backend) and is_map(caps) do
    where = "#{inspect(board)} backend #{inspect(backend)}"

    required =
      for {key, valid?} <- @required, not valid?.(Map.get(caps, key)) do
        "#{where}: #{key} is #{inspect(Map.get(caps, key))}"
      end

    experimental =
      case Map.fetch(caps, :experimental) do
        {:ok, value} when not is_boolean(value) -> ["#{where}: experimental is #{inspect(value)}"]
        _absent_or_boolean -> []
      end

    required ++ experimental ++ conversions(where, caps)
  end

  defp capabilities(board, backend, caps),
    do: ["#{inspect(board)}.backends/0 maps #{inspect(backend)} to #{inspect(caps)}"]

  defp conversions(where, caps) do
    case Map.fetch(caps, :conversions) do
      :error ->
        []

      {:ok, %{contracts: %{} = contracts}} ->
        evidence =
          if Capabilities.evidence(caps), do: [], else: ["#{where}: conversions name no evidence"]

        evidence ++
          for {contract, verdict} <- Enum.sort(contracts),
              not is_binary(contract) or Capabilities.conversion(caps, contract) != verdict do
            "#{where}: conversion #{inspect(contract)} => #{inspect(verdict)} is not " <>
              ":proven or {:unproven, reason}"
          end

      {:ok, other} ->
        ["#{where}: conversions is #{inspect(other)}, with no contracts map"]
    end
  end

  defp engine(board, backend, contract) do
    judge(board, :engine, [backend], fn
      %{module: module, canary: canary} when is_binary(canary) ->
        library(module, "backend #{inspect(backend)}'s engine", EngineNif, fn ->
          reports(module, contract)
        end)

      other ->
        ["#{inspect(board)}.engine(#{inspect(backend)}) is #{inspect(other)}"]
    end)
  end

  defp library(module, what, behaviour, loaded_check) do
    with :ok <- loaded(module, what),
         [] <- missing(module, behaviour) do
      loaded_check.()
    else
      {:error, violation} -> [violation]
      missing -> ["#{what} #{inspect(module)} does not export #{Enum.join(missing, ", ")}"]
    end
  end

  # A library that did not load is the board's preflight to report, by
  # name, and the node runs without it. One that loaded but predates
  # `contract/0` raises `:nif_not_loaded` from it: a mismatch like any other.
  defp reports(module, contract) do
    judge(module, :available?, [], fn
      true -> contract_violation(module, contract) ++ keys_violation(module)
      _not_loaded -> []
    end)
  end

  defp contract_violation(module, contract) do
    case call(module, :contract, []) do
      {:ok, ^contract} ->
        []

      {:ok, other} ->
        [
          "engine library #{inspect(module)} reports contract #{inspect(other)}; " <>
            "this base has contract #{contract}"
        ]

      {:error, _raised} ->
        [
          "engine library #{inspect(module)} loaded a library with no contract/0; " <>
            "this base has contract #{contract}"
        ]
    end
  end

  defp keys_violation(module) do
    expected = EngineNif.frame_meta_keys()

    judge(module, :frame_meta_keys, [], fn
      ^expected ->
        []

      other ->
        [
          "engine library #{inspect(module)} decodes frame metadata keys #{inspect(other)}; " <>
            "this base sends #{inspect(expected)}"
        ]
    end)
  end

  defp decoders(board, generic) do
    judge(board, :decoders, [], fn
      [_ | _] = names ->
        if Enum.all?(names, &is_binary/1) do
          Enum.flat_map(names, &decoder(board, &1)) ++
            Enum.flat_map([nil | names], &chain(board, &1, generic))
        else
          ["#{inspect(board)}.decoders/0 is #{inspect(names)}, not a list of strings"]
        end

      other ->
        ["#{inspect(board)}.decoders/0 is #{inspect(other)}, not a non-empty list"]
    end)
  end

  defp decoder(board, name) do
    judge(board, :decoder_backend, [name], fn module ->
      library(module, "decoder #{inspect(name)}'s library", DecoderNif, fn -> [] end)
    end)
  end

  defp chain(board, decoder, generic) do
    context = %{
      camera_id: "conformance",
      stream_params: %{},
      decoder: decoder,
      motion: nil,
      generic: generic
    }

    where = "#{inspect(board)}.detect_chain/1 for decoder #{inspect(decoder)}"

    judge(board, :detect_chain, [context], fn
      steps when is_list(steps) -> Enum.flat_map(steps, &step(where, &1))
      other -> ["#{where} is #{inspect(other)}, not a list"]
    end)
  end

  defp step(where, %Step{name: name, element: element}) do
    module = if is_struct(element), do: element.__struct__, else: element
    what = "#{where}: step #{inspect(name)}'s element"

    case loaded(module, what) do
      :ok ->
        if Membrane.Element.element?(module) or Membrane.Bin.bin?(module),
          do: [],
          else: ["#{what} #{inspect(module)} is not a Membrane element or bin"]

      {:error, violation} ->
        [violation]
    end
  end

  defp step(where, other), do: ["#{where}: #{inspect(other)} is not a %Cairn.Stage.Step{}"]

  defp profiles_dir(board) do
    judge(board, :profiles_dir, [], fn
      nil ->
        []

      dir when is_binary(dir) ->
        if File.dir?(dir),
          do: [],
          else: ["#{inspect(board)}.profiles_dir/0 #{dir} is no directory"]

      other ->
        ["#{inspect(board)}.profiles_dir/0 is #{inspect(other)}"]
    end)
  end

  defp judge(module, fun, args, judge) do
    case call(module, fun, args) do
      {:ok, value} -> judge.(value)
      {:error, violation} -> [violation]
    end
  end

  # A callback that raises is a violation too: the base would otherwise meet
  # the raise at config load or at a camera's start, far from the board.
  defp call(module, fun, args) do
    {:ok, apply(module, fun, args)}
  catch
    kind, reason ->
      {:error,
       "#{inspect(module)}.#{fun}(#{Enum.map_join(args, ", ", &inspect/1)}) raised " <>
         String.replace_prefix(Exception.format_banner(kind, reason, []), "** ", "")}
  end
end
