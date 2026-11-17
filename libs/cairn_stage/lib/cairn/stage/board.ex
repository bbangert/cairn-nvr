defmodule Cairn.Stage.Board do
  @moduledoc """
  What a release's board provides: its detect chain, the `decoder:` and
  `backend:` names it accepts, and the NIF modules behind them. One board is
  compiled into a release.
  """

  alias Cairn.Stage.Step

  @typedoc """
  What a board builds one camera's chain from. `generic` is the base's own
  steps for this camera, so a board can reuse the software decoder, the gate
  or ORT inference without depending on the base. `decoder` is the profile's
  decoder name when the caller knows it, else `nil`.
  """
  @type context :: %{
          camera_id: String.t(),
          stream_params: map(),
          decoder: String.t() | nil,
          motion: term() | nil,
          generic: [Step.t()]
        }

  @typedoc """
  `cpu_twin` is true when the CPU baseline cannot run the backend's artifact,
  so a profile on it must name an FP32 ONNX twin under `model.onnx`.
  """
  @type capabilities :: %{
          artifact: String.t(),
          fused_nms: boolean(),
          dynamic_shapes: boolean(),
          cpu_twin: boolean()
        }

  # Config errors name the release's board with it.
  @callback name() :: String.t()

  @callback detect_chain(context()) :: [Step.t()]

  @callback decoders() :: [String.t()]

  @callback backends() :: %{String.t() => capabilities()}

  # Takes the name because one board can carry several decode libraries.
  @callback decoder_backend(decoder_name :: String.t()) :: module()

  # `canary` is the probe-load executable run before a model is loaded in
  # the VM; it must link the same stages the engine does.
  @callback engine(backend_name :: String.t()) :: %{module: module(), canary: String.t()}

  # Each provided name whose device is absent on this host, with the reason,
  # per namespace: a profile naming one is valid but would do nothing. Both
  # maps empty when all are usable.
  @callback preflight() :: %{
              decoders: %{optional(String.t()) => String.t()},
              backends: %{optional(String.t()) => String.t()}
            }

  # Runtime files the board needs fetched; the shape is loose until a board
  # has some.
  @callback artifacts(context :: map()) :: [map()]

  @callback profiles_dir() :: Path.t() | nil
end
