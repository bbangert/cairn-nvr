defmodule Cairn.Board.Generic do
  @moduledoc """
  The board of a release built without a vendor layer: the base's own detect
  chain (`Cairn.Pipeline.DetectChain`), the ffmpeg-backed decode library and
  the onnxruntime engine for every name it accepts.
  """

  @behaviour Cairn.Stage.Board

  @impl true
  def name, do: "generic"

  @impl true
  def detect_chain(context), do: context.generic

  # Mirrors `DecoderKind` in `plugins/cairn-detect/src/decode.rs`: the video
  # decode path, not `backend:`'s inference runtime.
  @impl true
  def decoders, do: ~w(auto vaapi qsv nvdec v4l2 videotoolbox sw)

  # The host-side mirror of the `ORT` and `QNN` descriptors in
  # `plugins/cairn-detect/src/infer/backend.rs`, which carry the evidence
  # (rknn's is `Cairn.Rockchip.Board`'s, mirroring its own crate's `RKNN`).
  # Claims, not probes: config load answers them with no engine running and,
  # for a profile written ahead of its hardware, no device attached.
  #
  # `artifact` is the `model:` key naming the compiled file, not its format:
  # Rust reports `.onnx` for qnn (an onnxruntime execution provider) while
  # the key is `qnn:`, because its QDQ graph is a different file from the
  # fp32 export.
  #
  # `dynamic_shapes` is read by no rule: what it would refuse, an
  # `input_size:` disagreeing with a fixed-geometry artifact, is a fact about a
  # file the host cannot open, so `docs/profile-authoring.md` says it instead.
  #
  # `cpu_twin` has no Rust mirror — the baseline is the host's concern — and
  # is false on both rows: the CPU baseline runs qnn's QDQ `.onnx` itself.
  #
  # `experimental` has no Rust mirror either: it is the host's D-P10 policy,
  # under which ort is the only backend cleared of the acknowledgement and
  # qnn stays behind it.
  #
  # Only these two: a profile naming another backend is refused with this
  # board's name, because no engine in this release runs it.
  @impl true
  def backends do
    %{
      "ort" => %{
        artifact: "onnx",
        fused_nms: true,
        dynamic_shapes: true,
        cpu_twin: false,
        experimental: false
      },
      "qnn" => %{
        artifact: "qnn",
        fused_nms: false,
        dynamic_shapes: false,
        cpu_twin: false,
        experimental: true
      }
    }
  end

  @impl true
  def decoder_backend(_decoder), do: Cairn.Native

  @impl true
  def engine(_backend), do: %{module: CairnOrt, canary: "cairn-detect"}

  @impl true
  def preflight, do: %{decoders: %{}, backends: %{}}

  @impl true
  def artifacts(_context), do: []

  # The QCS6490's ladder, kept out of the base's `priv/profiles` because it
  # names `qnn`, which a board without that backend refuses.
  @impl true
  def profiles_dir, do: Application.app_dir(:cairn, "priv/profiles/generic")
end
