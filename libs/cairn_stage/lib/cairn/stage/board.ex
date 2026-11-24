defmodule Cairn.Stage.Board do
  @moduledoc """
  What a node's board provides: its detect chain, the `decoder:` and
  `backend:` names it accepts, and the NIF modules behind them. A node runs
  one board: one attached from a board directory, else the one its release
  was built with. `Cairn.Stage.Conformance` checks a module against this
  behaviour.
  """

  alias Cairn.Stage.Step

  @typedoc """
  What a board builds one camera's chain from. `generic` is the base's own
  steps for this camera, so a board can reuse the software decoder, the gate
  or ORT inference without depending on the base. `decoder` is the camera's
  resolved `decoder:` name, `nil` from a caller that names none.
  """
  @type context :: %{
          camera_id: String.t(),
          stream_params: map(),
          decoder: String.t() | nil,
          motion: term() | nil,
          generic: [Step.t()]
        }

  @typedoc """
  One backend's claims, answered at config load with no engine running.

  `artifact` is the `model:` key its compiled file is named under.
  `fused_nms` is whether it runs an export with the NMS op inside the graph,
  `dynamic_shapes` whether it accepts a graph that leaves a spatial dim
  symbolic. `cpu_twin` is true when the CPU baseline cannot run the
  artifact, so a profile on it must name an FP32 ONNX twin under
  `model.onnx`.

  `experimental` is true for a backend not yet proven in soak: a group runs
  it only when its profile and the operator both acknowledge that. Absent
  means true, so a board must say a backend is proven.

  `conversions` is for a backend whose artifact is converted from the
  contract's export by a tool that can break it: per decode contract (the
  canonical `model_profile:` family), whether the converted model was
  measured to detect, and `evidence`, where the measurements are. A backend
  without the key declares no verdicts, so config load checks none of its
  contracts. Read both keys through `Cairn.Stage.Capabilities`, which
  applies the defaults.
  """
  @type capabilities :: %{
          required(:artifact) => String.t(),
          required(:fused_nms) => boolean(),
          required(:dynamic_shapes) => boolean(),
          required(:cpu_twin) => boolean(),
          optional(:experimental) => boolean(),
          optional(:conversions) => %{
            evidence: String.t(),
            contracts: %{optional(String.t()) => conversion()}
          }
        }

  @typedoc "`{:unproven, why}` carries the measured failure a config diagnostic states."
  @type conversion :: :proven | {:unproven, String.t()}

  # Config errors name the node's board with it.
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

  @typedoc """
  A runtime file the board needs and a release does not carry, which the base
  downloads from `url` and keeps only if it hashes to `sha256` (hex). `size`,
  in bytes, also bounds the download. `backend` is the backend that cannot run
  without the file, so a camera on it is a config error while the file is
  missing. `env` is the variable the base sets to the file's path; one the
  operator has already set means they supplied the file, and the base neither
  fetches nor checks it.
  """
  @type artifact :: %{
          required(:name) => String.t(),
          required(:url) => String.t(),
          required(:sha256) => String.t(),
          optional(:size) => pos_integer(),
          optional(:backend) => String.t(),
          optional(:env) => String.t()
        }

  # The base passes `%{}`.
  @callback artifacts(context :: map()) :: [artifact()]

  @callback profiles_dir() :: Path.t() | nil
end
