defmodule Cairn.Pipeline.DetectChain do
  @moduledoc """
  A camera's detect branch from the picker to inference, as the node's
  board composes it (`c:Cairn.Stage.Board.detect_chain/1`). The base's own
  steps — decoder, the gate when one is configured, inference — reach the
  board in the context as `generic`; `Cairn.Board.Generic` returns them as
  they are.

  The chain is checked (`Cairn.Stage.Chain`) before a child is built, so a
  board that drops or repeats a stage, or links two formats that do not meet,
  is a build error naming the camera and the board rather than a branch that
  silently detects on the wrong frames.
  """

  import Membrane.ChildrenSpec

  alias Cairn.Motion
  alias Cairn.Pipeline.{Decoder, Inference, MotionGate, Picker}
  alias Cairn.Stage.{Chain, Step}

  @doc """
  `head` linked through the picker and every step, ending at the last one's
  output. `board` is the node's unless a test names another.
  """
  @spec build(Membrane.ChildrenSpec.builder(), map(), keyword(), module()) ::
          Membrane.ChildrenSpec.builder()
  def build(head, camera, detect, board \\ Cairn.Board.module()) do
    steps = steps(camera, detect, board)

    Enum.reduce(steps, child(head, :picker, Picker), &link/2)
  end

  # `via_in/3`'s spec types `min_demand_factor` as an integer while membrane's
  # own default is 0.25, so dialyzer reads every call passing a fractional
  # factor as one that cannot return.
  @dialyzer {:nowarn_function, link: 2}

  # One unit in flight between every pair: the upstream element learns the
  # downstream one is free the moment it is, and no more than one AU or frame
  # waits — which is what lets the decoder's latest-wins slot see inference's
  # real pace through any element in between that passes demand one-for-one.
  defp link(step, builder) do
    builder
    |> via_in(:input, target_queue_size: 1, min_demand_factor: 0.5)
    |> child(step.name, step.element)
  end

  defp steps(camera, detect, board) do
    stream_params = Keyword.get(detect, :stream_params, %{})
    gate = motion_gate(camera.id, stream_params)

    context = %{
      camera_id: camera.id,
      stream_params: stream_params,
      # `Cairn.Config.decoder/2`: the engine's decode library's name unless the
      # engine's config was pinned apart; a caller that passes none gets `nil`.
      decoder: Keyword.get(detect, :decoder),
      motion: gate && gate.config,
      generic: generic(camera, stream_params, gate),
      base: Cairn.Board.base()
    }

    steps = board.detect_chain(context)

    case Chain.validate(steps, Chain.required(gate != nil)) do
      :ok ->
        steps

      {:error, message} ->
        raise ArgumentError,
              "camera #{camera.id}: board #{board.name()}'s detect chain: #{message}"
    end
  end

  @doc """
  The base's own steps for a camera with no motion gate, as `detect_chain/1`
  receives them in `generic`: what conformance checks a board's chain on.
  """
  @spec base_steps(String.t()) :: [Step.t()]
  def base_steps(camera_id), do: generic(%{id: camera_id}, %{}, nil)

  defp generic(camera, stream_params, gate) do
    decoder = %Step{
      name: :decoder,
      element: %Decoder{camera_id: camera.id, stream_params: decoder_params(stream_params, gate)},
      covers: [:decode, :scale],
      input: :h264,
      output: :rgb
    }

    infer = %Step{
      name: :infer,
      element: %Inference{
        session: {Cairn.Native.Host, Cairn.Native.Host},
        stream_id: camera.id,
        stream_params: stream_params
      },
      covers: [:infer],
      input: :rgb,
      output: :detections
    }

    case gate do
      nil ->
        [decoder, infer]

      gate ->
        [
          decoder,
          %Step{name: :motion_gate, element: gate, covers: [:motion], input: :rgb, output: :rgb},
          infer
        ]
    end
  end

  # The Nx measurement (D-C3): a configured gate becomes an element between
  # decoder and inference, and the decoder is told nothing about motion — the
  # verdict in the buffer metadata comes from `Cairn.Pipeline.MotionGate`
  # instead of from the decode NIF, behind the same contract. A bad
  # motion_json raises here, at pipeline build, where the operator reads a
  # config error rather than a per-frame one.
  defp motion_gate(camera_id, stream_params) do
    case Motion.Config.resolve_json(Map.get(stream_params, :motion_json)) do
      {:ok, nil} ->
        nil

      {:ok, config} ->
        %MotionGate{config: config}

      {:error, message} ->
        raise ArgumentError, "camera #{camera_id}: motion_json: #{message}"
    end
  end

  # `Cairn.Pipeline.Inference` keeps the FULL stream params — the gate
  # *policy* (linger/epoch bypass/re-verify) lives with the model session and
  # still reads these knobs; only the measurement moved.
  defp decoder_params(stream_params, nil), do: stream_params
  defp decoder_params(stream_params, _gate), do: Map.put(stream_params, :motion_json, nil)
end
