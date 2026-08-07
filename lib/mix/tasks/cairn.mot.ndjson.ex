defmodule Mix.Tasks.Cairn.Mot.Ndjson do
  @shortdoc "Drives the tracker from a captured cairn-detect ndjson run"

  @moduledoc """
  End-to-end MOT harness mode: replays a captured plugin stdout run —
  real detector, real embeddings — through the real `Cairn.PluginProtocol`
  into `Cairn.Tracker`, and writes MOT-format predictions.

      mix cairn.mot.ndjson run.ndjson \\
        --seq tools/mot-bench/data/mot17_img/train/MOT17-04 \\
        --out tools/mot-bench/data/preds/e2e/MOT17-04.txt \\
        --bbd --reid

  `--seq` names the ground-truth sequence directory (`seqinfo.ini` supplies
  the frame rate the predictions are scored against and the pixel
  dimensions MOT output is written in). The capture is whatever
  `tools/mot-bench/e2e.py` teed from cairn-detect while the sequence's
  video played in real time.

  Every `frame.objects` line — including empty liveness lines — is one
  tracker batch: `at_ms` is the line's own media time (the RTP 90 kHz
  clock, so a replay of one capture is deterministic), and the MOT frame
  index is that media time mapped onto the native-rate grid,
  `round(media_ms / 1000 × fps) + 1`. A second sample landing on an
  already-written frame index is dropped and counted (`frames_deduped` —
  the grid has one slot per frame and the earlier sample was already
  scored into it), and a sample mapped past the grid — a looped or
  overrun feed — is counted apart (`frames_past_grid`, a number that
  should be ~0; more is an fps mismatch). Lines the protocol rejects
  whole are `lines_invalid`; objects dropped inside otherwise-valid
  lines are `objects_invalid`; `objects_embedded` counts only what the
  tracker actually consumed (kept frames). hello/status/unknown types
  are ignored silently, as the host ignores them.

  Options are `mix cairn.mot.track`'s policy surface: `--bbd`, `--oru`,
  `--ocr`, `--reid`, `--twin-mint`, `--min-score`, the policy scalars, and
  `--fps` to override `seqinfo.ini`. There is no `--det-min` — the plugin
  already applied its own floors before the capture.
  """

  use Mix.Task

  alias Cairn.{MotBench, PluginProtocol}
  alias Mix.Tasks.Cairn.Mot.Track

  @switches [
    seq: :string,
    out: :string,
    bbd: :boolean,
    oru: :boolean,
    ocr: :boolean,
    reid: :boolean,
    twin_mint: :boolean,
    min_score: :float,
    fps: :float,
    max_unseen_ms: :integer,
    max_live_tracks: :integer,
    stationary_after_ms: :integer
  ]

  @impl true
  def run(argv) do
    {opts, positional, invalid} = OptionParser.parse(argv, strict: @switches)

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    ndjson =
      case positional do
        [path] -> path
        _other -> Mix.raise("usage: mix cairn.mot.ndjson NDJSON_FILE --seq DIR --out FILE")
      end

    seq_dir = opts[:seq] || Mix.raise("--seq is required")
    out = opts[:out] || Mix.raise("--out is required")

    seqinfo = Track.parse_seqinfo!(Path.join(seq_dir, "seqinfo.ini"))
    fps = opts[:fps] || seqinfo.frame_rate

    if fps <= 0, do: Mix.raise("fps must be > 0, got #{fps}")

    policy = MotBench.policy(opts)

    {frames, stats} = decode!(ndjson, fps, seqinfo.seq_length)
    {lines, emitted, minted} = MotBench.drive(frames, seqinfo, policy)

    MotBench.write_pred!(out, lines)

    MotBench.write_sidecar(out, %{
      task: "cairn.mot.ndjson",
      seq: seqinfo.name,
      seq_dir: seq_dir,
      ndjson: ndjson,
      fps: fps,
      seq_length: seqinfo.seq_length,
      image_size: [seqinfo.im_width, seqinfo.im_height],
      lines_total: stats.total,
      lines_objects: stats.objects,
      lines_invalid: stats.lines_invalid,
      objects_invalid: stats.objects_invalid,
      frames_deduped: stats.deduped,
      frames_past_grid: stats.past_grid,
      objects_embedded: stats.embedded,
      lines_emitted: emitted,
      tracks_minted: minted,
      policy: policy
    })

    Mix.shell().info(
      "#{seqinfo.name}: #{stats.objects} frame lines " <>
        "(#{stats.lines_invalid} invalid lines, #{stats.objects_invalid} invalid objects, " <>
        "#{stats.deduped} deduped, #{stats.past_grid} past grid, " <>
        "#{stats.embedded} embedded objects) -> " <>
        "#{emitted} lines out, #{minted} tracks -> #{out}"
    )
  end

  # One pass over the capture: decode through the real protocol, keep the
  # frame.objects lines, map each onto the gt frame grid, dedupe by frame.
  defp decode!(path, fps, seq_length) do
    content =
      case File.read(path) do
        {:ok, content} -> content
        {:error, reason} -> Mix.raise("cannot read ndjson at #{path}: #{inspect(reason)}")
      end

    initial =
      {[], MapSet.new(),
       %{
         total: 0,
         objects: 0,
         lines_invalid: 0,
         objects_invalid: 0,
         deduped: 0,
         past_grid: 0,
         embedded: 0
       }}

    {frames, _seen, stats} =
      content
      |> String.split("\n", trim: true)
      |> Enum.reduce(initial, fn line, {frames, seen, stats} ->
        stats = %{stats | total: stats.total + 1}

        case PluginProtocol.decode_line(line, :camera) do
          {:objects, observation} ->
            keep(frames, seen, stats, observation, fps, seq_length)

          {:error, _reason} ->
            {frames, seen, %{stats | lines_invalid: stats.lines_invalid + 1}}

          _ignored ->
            {frames, seen, stats}
        end
      end)

    {Enum.reverse(frames), stats}
  end

  # One decoded frame line onto the gt grid: counted, deduped by frame
  # slot, with past-the-grid samples (a looped or overrun feed) counted
  # apart so an fps mismatch cannot hide inside the dedupe number.
  # Embeddings are tallied for kept frames only — the sidecar's number is
  # what the tracker consumed, not what the capture carried.
  defp keep(frames, seen, stats, observation, fps, seq_length) do
    {frame, at_ms} = MotBench.frame_for(observation, fps)

    stats = %{
      stats
      | objects: stats.objects + 1,
        objects_invalid: stats.objects_invalid + observation.invalid_objects
    }

    cond do
      frame > seq_length ->
        {frames, seen, %{stats | past_grid: stats.past_grid + 1}}

      MapSet.member?(seen, frame) ->
        {frames, seen, %{stats | deduped: stats.deduped + 1}}

      true ->
        embedded = Enum.count(observation.objects, &Map.has_key?(&1, :embedding))

        {[{frame, at_ms, observation.objects} | frames], MapSet.put(seen, frame),
         %{stats | embedded: stats.embedded + embedded}}
    end
  end
end
