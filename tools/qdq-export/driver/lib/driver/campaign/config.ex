defmodule Driver.Campaign.Config do
  @moduledoc """
  Campaign knobs, defaults identical to the bash driver's (same env
  overrides: BOARD, OUT, CLIPS). `qdq_dir` is where the board scripts,
  analyzers, and evidence tree live — the driver project's parent.
  """

  # The shipped defective nano, byte-for-byte: the sensitivity control is
  # only a control if THESE bytes ran (see do_content in the bash driver).
  @old_nano_sha "e4bb2552c6f3c810ae6fc40686f6b4cac5e21eab885b868e6469a2c87098627d"

  defstruct host: "192.168.2.87",
            qdq_dir: nil,
            out: nil,
            container: "addon_c2da371c_cairn",
            clips: ~w(ac86 f58a aeb4),
            qnn_session_budget: 18,
            qnn_flags:
              "--qnn-library /data/qnn-spike/lib/libonnxruntime_providers_qnn.so " <>
                "--qnn-soc-model 35 --qnn-htp-arch 68",
            old_nano_sha: @old_nano_sha,
            ssh: Driver.Board.Ssh.Cmd,
            # Test seams: stage logic runs against a scripted board module
            # and relocated board paths; defaults are the real thing.
            board: Driver.Board,
            bench_dir: "/data/cairn-bench",
            clip_dir: "/data",
            spike_cmd: "sh /data/qnn-spike/run_spike.sh 20",
            reboot_opts: []

  @type t :: %__MODULE__{}

  @spec new(keyword()) :: t()
  def new(overrides \\ []) do
    qdq_dir = Keyword.get(overrides, :qdq_dir, Path.expand("..", File.cwd!()))

    defaults = [
      qdq_dir: qdq_dir,
      host: System.get_env("BOARD", "192.168.2.87"),
      out: System.get_env("OUT", Path.join(qdq_dir, "out-20260820")),
      clips: System.get_env("CLIPS", "ac86 f58a aeb4") |> String.split()
    ]

    struct!(__MODULE__, Keyword.merge(defaults, overrides))
  end

  def htp(%__MODULE__{out: out}), do: Path.join(out, "htp")
  def art(%__MODULE__{out: out}), do: Path.join(out, "artifacts")

  @doc """
  The 12 board-worthy rungs (phase 2.3 verdicts): every a16 plus the
  three a8 survivors. Raw yolo26/yolov8 heads decode under the yolov8
  profile (the bundled binary's contract). Order is the campaign order.
  """
  @spec rungs() :: [{String.t(), String.t(), pos_integer()}]
  def rungs do
    [
      {"yolox_nano-qdq-a16", "yolox", 416},
      {"yolox_tiny-qdq-a16", "yolox", 416},
      {"yolox_tiny-qdq-a8", "yolox", 416},
      {"yolox_s-qdq-a16", "yolox", 640},
      {"yolox_s-qdq-a8", "yolox", 640},
      {"yolox_m-qdq-a16", "yolox", 640},
      {"yolox_m-qdq-a8", "yolox", 640},
      {"yolo26n-qdq-a16", "yolov8", 640},
      {"yolo26n-416-qdq-a16", "yolov8", 416},
      {"yolo26s-qdq-a16", "yolov8", 640},
      {"yolo26m-qdq-a16", "yolov8", 640},
      {"yolov8n-qdq-a16", "yolov8", 640}
    ]
  end
end
