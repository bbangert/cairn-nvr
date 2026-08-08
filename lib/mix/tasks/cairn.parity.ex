defmodule Mix.Tasks.Cairn.Parity do
  @shortdoc "Compares the external plugin and the in-VM NIF on the same clips"

  @moduledoc """
  Phase 2's proof (membrane-port task 2.5): the same clips through
  `cairn-detect` over RTP and through `cairn-native` in this VM must yield the
  same detections.

      mix cairn.parity --model plugins/cairn-detect/yolox_nano.onnx \\
        --labels plugins/cairn-detect/coco.names \\
        data/events/reolink_main/*.mp4

  rfdetr needs **both** `--input-size 384` and the 91-slot category space:

      mix cairn.parity --model plugins/cairn-detect/rfdetr_nano.onnx \\
        --labels plugins/cairn-detect/coco91.names --input-size 384 <clip>

  Needs `cargo build --release` in **both** `plugins/cairn-detect` and
  `plugins/cairn-native`, with the latter's `libcairn_native.so` copied to
  `priv/native/`; plus ffmpeg, ffprobe and python3 on PATH. Exits nonzero on
  anything but parity — a divergence, or an alignment too ambiguous to have
  compared the frames it claims to — so it is usable as a gate.

  Options beyond the above: `--plugin` (binary path), `--sample-fps` (30),
  `--min-score` (JSON, `{"default":0.3}`), `--tolerance` (1.0e-9 — read
  `Cairn.Native.Parity`'s moduledoc before widening it), `--max-frames`,
  `--out` (dump both sides as ndjson for `verify/compare_runs.py`),
  `--work-dir`, `--udp-port`, `--model-profile`, `--embedder-model` (which is
  what puts an `embedding` on every `person` and so compares the Re-ID feature
  through base64 on one path and raw bytes on the other).

  The app is configured but not started: its supervision tree owns real camera
  ports, and this task wants the NIF and the protocol codec, neither of which
  needs a running system.
  """

  use Mix.Task

  alias Cairn.Native.Parity

  @requirements ["app.config"]

  @switches [
    model: :string,
    labels: :string,
    input_size: :string,
    model_profile: :string,
    embedder_model: :string,
    plugin: :string,
    sample_fps: :integer,
    min_score: :string,
    tolerance: :float,
    max_frames: :integer,
    coverage: :float,
    udp_port: :integer,
    work_dir: :string,
    out: :string
  ]

  @impl true
  def run(argv) do
    {opts, clips} = OptionParser.parse!(argv, strict: @switches)

    if clips == [], do: Mix.raise("give at least one clip")
    unless opts[:model], do: Mix.raise("--model is required")

    reports = Parity.run(clips, options(opts))

    # Anything that is not parity, not just a divergence: a clip whose two runs
    # could not be lined up (`:ambiguous_alignment`) compared nothing, and a gate
    # that exits 0 on it is a gate that passed without looking.
    case Enum.reject(reports, &(&1.verdict == :parity)) do
      [] -> Mix.shell().info("\nPARITY on #{length(reports)} clip(s)")
      failed -> Mix.raise("NOT PARITY — " <> Enum.map_join(failed, ", ", &failure/1))
    end
  end

  defp failure(report), do: "#{Path.basename(report.clip)}: #{report.verdict}"

  defp options(opts) do
    opts
    |> Keyword.take([
      :model,
      :labels,
      :input_size,
      :model_profile,
      :embedder_model,
      :plugin,
      :sample_fps,
      :tolerance,
      :max_frames,
      :coverage,
      :udp_port,
      :work_dir,
      :out
    ])
    |> put_min_score(opts[:min_score])
    |> Keyword.put(:log, fn message -> Mix.shell().info(message) end)
    |> Keyword.put(:on_report, &table/1)
  end

  defp put_min_score(opts, nil), do: opts
  defp put_min_score(opts, json), do: Keyword.put(opts, :min_score, Jason.decode!(json))

  defp table(report) do
    Mix.shell().info("""

    #{report.clip}
      verdict            #{report.verdict}
      access units       #{report.expected_frames}
      frames  plugin     #{report.plugin_frames}
              native     #{report.native_frames} (#{percent(report.native_share)} of the clip)
              matched    #{report.matched} (#{percent(report.coverage)} of the plugin's, \
    in window)
              plugin-only #{report.plugin_only}   native-only #{report.native_only}   \
    plugin outside the window #{report.plugin_outside}
      objects compared   #{report.objects}
      pts offset         #{report.pts_offset} (#{report.alignment.agreed}/\
    #{report.alignment.probes} probe frames agree, margin #{report.alignment.margin})
      mismatches         #{length(report.mismatches)}
      expected diffs     sequence: #{report.expected_differences.plugin_sequence_present} plugin \
    / #{report.expected_differences.native_sequence_nil} native nil of \
    #{report.expected_differences.frames}\
    """)

    report.mismatches
    |> Enum.take(20)
    |> Enum.each(&Mix.shell().info("      ! " <> inspect(&1, limit: :infinity)))
  end

  defp percent(share), do: "#{Float.round(share * 100, 1)}%"
end
