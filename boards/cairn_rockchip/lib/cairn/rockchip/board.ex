defmodule Cairn.Rockchip.Board do
  @moduledoc """
  The board of a Rockchip release: the base's generic detect chain, with the
  RKNN engine (`Cairn.Rockchip.Native`) behind its inference step for
  `backend: rknn`, and for `decoder: rkmpp` its decode step replaced by MPP
  decode and RGA scale (`Cairn.Rockchip.DecodeScale`) plus the
  `Cairn.Rockchip.Download` that turns their dma-buf frames back into RGB.

  The base's own libraries — the ffmpeg-backed decoder, the decoder host, the
  onnxruntime engine and its canary — are lent through
  `config :cairn_rockchip, :generic`, which the base's
  `config/boards/rockchip.exs` sets: this library depends only on
  `cairn_stage`, so it cannot name a base module itself.
  """

  @behaviour Cairn.Stage.Board

  alias Cairn.Rockchip.{DecodeScale, Download, Native}
  alias Cairn.Stage.Step

  # What rknn-toolkit2 and librknnrt 2.3.2 were measured to do with each
  # decode contract's export. `:proven` converted to INT8, ran on the RK3566
  # NPU and detected there. An unproven reason is the toolkit simulator's
  # except where it names the board. Per contract, not per model size (a
  # yolox_nano build passes as yolox and detected nothing in INT8 in the
  # simulator) nor per family (yolov9 was never converted and shares yolov8's;
  # yolov10's is yolo26's export of that head). Rockchip's model zoo covers v8
  # and v11 through the head cut before its box decode: `yolov8split`'s
  # layout, not `yolov8`'s. The backend opens INT8 artifacts only, so an FP16
  # result in a reason is the runtime's, measured by the bench harness.
  @conversions %{
    "yolox" => :proven,
    "yolov8split" => :proven,
    "yolo26split" => :proven,
    "yolov10" =>
      {:unproven,
       "its end-to-end output detects nothing in INT8 in the toolkit's simulator and " <>
         "has wrong boxes in FP16 on the board, both measured on yolo26's export of " <>
         "that head"},
    "yolov8" =>
      {:unproven,
       "a whole-head export carries pixel-range boxes and 0..1 scores in one output, " <>
         "whose one INT8 scale zeroes the scores (yolov8, yolo11 and yolo26 detected " <>
         "nothing in the toolkit's simulator); their split exports detect on the board " <>
         "(model_profile yolov8split for v8 and v11, yolo26split for yolo26)"},
    "rfdetr" =>
      {:unproven,
       "its INT8 scores are unusable in the toolkit's simulator and no INT8 build ran " <>
         "on the board, where its FP16 build crashed librknnrt 2.3.2 (no GridSample op)"}
  }

  @impl true
  def name, do: "rockchip"

  # Still named `:decoder`, the child tools read decoder stats from. The NIF
  # refuses a `motion_json`, and measures none: a configured gate is the
  # generic `:motion_gate` step after the download.
  @impl true
  def detect_chain(%{decoder: "rkmpp"} = context) do
    decode = %Step{
      name: :decoder,
      element: %DecodeScale{
        camera_id: context.camera_id,
        host: generic(:host),
        stream_params: Map.put(context.stream_params, :motion_json, nil)
      },
      covers: [:decode, :scale],
      input: :h264,
      output: :dma_frame
    }

    download = %Step{
      name: :download,
      element: %Download{},
      covers: [],
      input: :dma_frame,
      output: :rgb
    }

    [decode, download | Enum.reject(context.generic, &(:decode in &1.covers))]
  end

  def detect_chain(context), do: context.generic

  # `auto` stays software: `rkmpp` is only ever named (D-G11).
  @impl true
  def decoders, do: ~w(auto sw rkmpp)

  # No `qnn`: this board has no HTP, so a profile naming it is refused with
  # this board's name. Only librknnrt runs an `.rknn`, so the CPU baseline
  # needs `rknn`'s twin. `rknn` stays experimental until it has soaked.
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
      "rknn" => %{
        artifact: "rknn",
        fused_nms: false,
        dynamic_shapes: false,
        cpu_twin: true,
        experimental: true,
        conversions: %{evidence: "tools/rknn-export/README.md", contracts: @conversions}
      }
    }
  end

  @impl true
  def decoder_backend("rkmpp"), do: Native
  def decoder_backend(_decoder), do: generic(:decoder)

  @impl true
  def engine("rknn"), do: %{module: Native, canary: "cairn-rockchip-probe"}
  def engine(_backend), do: generic(:engine)

  # Every reason that applies, so fixing one does not uncover the next on the
  # following boot. The base sets `CAIRN_RKNN_LIBRARY` to where it downloads
  # the library (`artifacts/1`) unless the operator set it first; unset means
  # the loader's search path, which cannot be checked from here.
  @impl true
  def preflight do
    nif = nif_reason(Native.load_error())

    %{
      decoders: named("rkmpp", [nif | Enum.map(devices(), &device_reason/1)]),
      backends: named("rknn", [nif, library_reason()])
    }
  end

  defp named(name, reasons) do
    case Enum.reject(reasons, &is_nil/1) do
      [] -> %{}
      reasons -> %{name => Enum.join(reasons, "; ")}
    end
  end

  @devices ~w(/dev/mpp_service /dev/rga /dev/dma_heap/system)

  # Overridable so a suite can point at paths that do or do not exist.
  defp devices, do: Application.get_env(:cairn_rockchip, :devices, @devices)

  defp device_reason(path), do: unless(File.exists?(path), do: "#{path} is missing")

  defp nif_reason(nil), do: nil
  defp nif_reason(error), do: "the board NIF did not load (#{inspect(error)})"

  # `rknn.rs` treats only an unset variable as the search path; an empty one
  # is handed to the loader as given.
  defp library_reason do
    case System.get_env("CAIRN_RKNN_LIBRARY") do
      nil ->
        nil

      "" ->
        "CAIRN_RKNN_LIBRARY is set but empty, and the engine opens it as given " <>
          "rather than searching the loader's path"

      library ->
        unless File.regular?(library),
          do: "CAIRN_RKNN_LIBRARY names #{library}, which is not a regular file"
    end
  end

  # Rockchip's licence for librknnrt does not permit redistributing it, so no
  # release carries it: the base downloads it from Rockchip's own repository,
  # pinned by commit and hash. librknnrt 2.3.2, the version `rknn/sys.rs` is
  # written against.
  @rknn_toolkit2_commit "42aa1d426c0a9e0869b6374edba009f7208a1926"
  @librknnrt_sha256 "d31fc19c85b85f6091b2bd0f6af9d962d5264a4e410bfb536402ec92bac738e8"
  @librknnrt_size 7_726_232

  @impl true
  def artifacts(_context) do
    [
      %{
        name: "librknnrt.so",
        url:
          "https://raw.githubusercontent.com/airockchip/rknn-toolkit2/#{@rknn_toolkit2_commit}" <>
            "/rknpu2/runtime/Linux/librknn_api/aarch64/librknnrt.so",
        sha256: @librknnrt_sha256,
        size: @librknnrt_size,
        backend: "rknn",
        env: "CAIRN_RKNN_LIBRARY"
      }
    ]
  end

  @impl true
  def profiles_dir, do: Application.app_dir(:cairn_rockchip, "priv/profiles")

  defp generic(key),
    do: :cairn_rockchip |> Application.fetch_env!(:generic) |> Keyword.fetch!(key)
end
