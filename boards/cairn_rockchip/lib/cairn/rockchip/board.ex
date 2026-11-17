defmodule Cairn.Rockchip.Board do
  @moduledoc """
  The board of a Rockchip release: the base's generic detect chain, with the
  RKNN engine (`Cairn.Rockchip.Native`) behind its inference step for
  `backend: rknn`.

  The base's own libraries — the ffmpeg-backed decoder, the onnxruntime engine
  and its canary — are lent through `config :cairn_rockchip, :generic`, which
  the base's `config/boards/rockchip.exs` sets: this library depends only on
  `cairn_stage`, so it cannot name a base module itself.
  """

  @behaviour Cairn.Stage.Board

  alias Cairn.Rockchip.Native

  @impl true
  def name, do: "rockchip"

  @impl true
  def detect_chain(context), do: context.generic

  # Software decode only until the MPP decoder lands (phase 9).
  @impl true
  def decoders, do: ~w(auto sw)

  # No `qnn`: this board has no HTP, so a profile naming it is refused with
  # this board's name. Only librknnrt runs an `.rknn`, so the CPU baseline
  # needs `rknn`'s twin.
  @impl true
  def backends do
    %{
      "ort" => %{artifact: "onnx", fused_nms: true, dynamic_shapes: true, cpu_twin: false},
      "rknn" => %{artifact: "rknn", fused_nms: false, dynamic_shapes: false, cpu_twin: true}
    }
  end

  @impl true
  def decoder_backend(_decoder), do: generic(:decoder)

  @impl true
  def engine("rknn"), do: %{module: Native, canary: "cairn-rockchip-probe"}
  def engine(_backend), do: generic(:engine)

  # Every reason that applies, so fixing one does not uncover the next on the
  # following boot. `CAIRN_RKNN_LIBRARY` unset means the loader's search path,
  # which cannot be checked from here.
  @impl true
  def preflight do
    reasons =
      Enum.reject([nif_reason(Native.load_error()), library_reason()], &is_nil/1)

    backends = if reasons == [], do: %{}, else: %{"rknn" => Enum.join(reasons, "; ")}
    %{decoders: %{}, backends: backends}
  end

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

  @impl true
  def artifacts(_context), do: []

  @impl true
  def profiles_dir, do: nil

  defp generic(key),
    do: :cairn_rockchip |> Application.fetch_env!(:generic) |> Keyword.fetch!(key)
end
