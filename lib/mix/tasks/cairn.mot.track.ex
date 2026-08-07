defmodule Mix.Tasks.Cairn.Mot.Track do
  @shortdoc "Drives the tracker over a MOT sequence's public detections"

  @moduledoc """
  Tracker-only MOT harness mode: feeds a MOTChallenge sequence's public
  detections through `Cairn.Tracker` and writes MOT-format predictions.

      mix cairn.mot.track tools/mot-bench/data/mot17/train/MOT17-04-SDP \\
        --out tools/mot-bench/data/preds/base/MOT17-04-SDP.txt \\
        --bbd --oru --min-score 0.25

  The sequence directory must contain `seqinfo.ini` and `det/det.txt`.
  Output is one `frame,id,x,y,w,h,1,-1,-1,-1` line per tracked detection,
  plus a `<out root>.config.json` sidecar echoing the full run config —
  `tools/mot-bench/score.py` folds sidecars into its report so every
  number stays re-derivable.

  No pixels are involved: this mode isolates association quality
  (AssA/IDF1) from our detector. End-to-end mode is separate tooling.

  ## Options

    * `--out` (required) — prediction file to write
    * `--bbd` / `--no-bbd` — batch boundary-damping stage (default off,
      matching production defaults)
    * `--oru` / `--no-oru` — observation-reuse stage (default off)
    * `--ocr` / `--no-ocr` — observation-centric recovery stage (default off)
    * `--reid` / `--no-reid` — Re-ID appearance fusion inside the bbd admission
      (default off). A tracker-only run carries no embeddings — no plugin runs
      here to produce them — so this flag only matters once a det file (or a
      future E2E run) carries the phase-4 embedding field for the fusion to
      read; until then it is accepted but inert.
    * `--twin-mint` / `--no-twin-mint` — twin-mint guard (default on)
    * `--min-score FLOAT` — tracker admission floor (`min_score`
      `"default"` key; default 0.5). `0.0` floors nothing.
    * `--det-min FLOAT` — drop detections below this *raw* det.txt
      confidence before the tracker sees them (default keep all).
      Detector confidences are then clamped to `0..1` — DPM's raw SVM
      scores saturate, so gate DPM here, not with the clamp.
    * `--fps FLOAT` — override `seqinfo.ini` frameRate. Frame time is
      `(frame - 1) * 1000 / fps` ms; TrackEval does not auto-map rates,
      so rate-mismatch runs go through `tools/mot-bench/convert/resample.py`
      instead of this flag.
    * `--max-unseen-ms` / `--max-live-tracks` / `--stationary-after-ms` —
      policy scalars (defaults 3000 / 128 / 10000, the soak policy).

  Track IDs are ULIDs internally (nondeterministic); output IDs are
  first-seen ordinals, so two runs over the same input are byte-identical.
  """

  use Mix.Task

  alias Cairn.{Observation, Tracker}

  @camera_id "mot"

  @switches [
    out: :string,
    bbd: :boolean,
    oru: :boolean,
    ocr: :boolean,
    reid: :boolean,
    twin_mint: :boolean,
    min_score: :float,
    det_min: :float,
    fps: :float,
    max_unseen_ms: :integer,
    max_live_tracks: :integer,
    stationary_after_ms: :integer
  ]

  @impl true
  def run(argv) do
    {opts, positional, invalid} = OptionParser.parse(argv, strict: @switches)

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    seq_dir =
      case positional do
        [dir] -> dir
        _other -> Mix.raise("usage: mix cairn.mot.track SEQ_DIR --out FILE [options]")
      end

    out = opts[:out] || Mix.raise("--out is required")

    seqinfo = parse_seqinfo!(Path.join(seq_dir, "seqinfo.ini"))
    fps = opts[:fps] || seqinfo.frame_rate

    if fps <= 0, do: Mix.raise("fps must be > 0, got #{fps}")
    policy = policy(opts)
    det_min = opts[:det_min]

    {dets_by_frame, stats} =
      load_detections!(Path.join([seq_dir, "det", "det.txt"]), seqinfo, det_min)

    {lines, emitted, minted} = track_sequence(dets_by_frame, seqinfo, fps, policy)

    File.mkdir_p!(Path.dirname(out))
    File.write!(out, lines)

    write_sidecar(out, %{
      seq_dir: seq_dir,
      seqinfo: seqinfo,
      fps: fps,
      policy: policy,
      det_min: det_min,
      stats: stats,
      emitted: emitted,
      minted: minted
    })

    Mix.shell().info(
      "#{seqinfo.name}: #{stats.kept}/#{stats.total} detections in, " <>
        "#{emitted} lines out, #{minted} tracks -> #{out}"
    )
  end

  # -- tracking ---------------------------------------------------------------

  defp track_sequence(dets_by_frame, seqinfo, fps, policy) do
    initial = {Tracker.new(), %{ids: %{}, next: 1}, [], 0}

    {_tracker, canon, lines, emitted} =
      Enum.reduce(1..seqinfo.seq_length, initial, fn frame, {tracker, canon, lines, emitted} ->
        at_ms = at_ms(frame, fps)
        objects = Map.get(dets_by_frame, frame, [])

        observation = %Observation{
          camera_id: @camera_id,
          epoch: @camera_id,
          at_ms: at_ms,
          observed_at: wall(at_ms)
        }

        context = Tracker.context(observation, @camera_id, policy)
        {tracker, tagged, _events} = Tracker.track(tracker, objects, context)

        {canon, frame_lines} = emit_frame(frame, tagged, seqinfo, canon)
        {tracker, canon, [lines, frame_lines], emitted + length(tagged)}
      end)

    {lines, emitted, canon.next - 1}
  end

  # Ordinals are assigned at first sight in `tagged` order, which is input
  # order and therefore deterministic even though ULIDs are not.
  defp emit_frame(frame, tagged, seqinfo, canon) do
    {frame_lines, canon} =
      Enum.map_reduce(tagged, canon, fn %{object_id: object_id, bbox: bbox}, canon ->
        {ordinal, canon} = ordinal(canon, object_id)
        {mot_line(frame, ordinal, bbox, seqinfo), canon}
      end)

    {canon, frame_lines}
  end

  defp ordinal(%{ids: ids, next: next} = canon, object_id) do
    case ids do
      %{^object_id => ordinal} -> {ordinal, canon}
      _missing -> {next, %{canon | ids: Map.put(ids, object_id, next), next: next + 1}}
    end
  end

  defp mot_line(frame, id, [x, y, w, h], %{im_width: iw, im_height: ih}) do
    [
      Integer.to_string(frame),
      ",",
      Integer.to_string(id),
      ",",
      px(x * iw),
      ",",
      px(y * ih),
      ",",
      px(w * iw),
      ",",
      px(h * ih),
      ",1,-1,-1,-1\n"
    ]
  end

  defp px(value), do: :erlang.float_to_binary(value / 1, decimals: 2)

  # MOT frames are 1-indexed; frame 1 is t=0 and each step advances 1000/fps.
  @doc false
  def at_ms(frame, fps), do: round((frame - 1) * 1000 / fps)

  # `observed_at` is reporting data, not a clock the tracker decides on
  # (same convention as the golden harness).
  defp wall(at_ms), do: DateTime.add(~U[2026-07-26 12:00:00Z], at_ms, :millisecond)

  # -- policy -----------------------------------------------------------------

  # Scalar defaults mirror the soak/golden policy; stage flags default to the
  # production defaults (bbd/oru/ocr off, twin_mint on). Hardcoded rather than
  # read from `Cairn.Config`: a measurement must not move because a config
  # default did.
  defp policy(opts) do
    %{
      max_unseen_ms: Keyword.get(opts, :max_unseen_ms, 3_000),
      max_live_tracks: Keyword.get(opts, :max_live_tracks, 128),
      stationary_after_ms: Keyword.get(opts, :stationary_after_ms, 10_000),
      min_score: %{"default" => Keyword.get(opts, :min_score, 0.5)},
      bbd: Keyword.get(opts, :bbd, false),
      oru: Keyword.get(opts, :oru, false),
      ocr: Keyword.get(opts, :ocr, false),
      reid: Keyword.get(opts, :reid, false),
      twin_mint: Keyword.get(opts, :twin_mint, true)
    }
  end

  # -- input parsing ----------------------------------------------------------

  @doc false
  def parse_seqinfo!(path) do
    fields =
      path
      |> read!("seqinfo.ini")
      |> String.split(["\n", "\r\n"], trim: true)
      |> Enum.flat_map(fn line ->
        case String.split(line, "=", parts: 2) do
          [key, value] -> [{String.trim(key), String.trim(value)}]
          _other -> []
        end
      end)
      |> Map.new()

    %{
      name: fetch_field!(fields, "name", path),
      frame_rate: parse_number!(fetch_field!(fields, "frameRate", path)),
      seq_length: String.to_integer(fetch_field!(fields, "seqLength", path)),
      im_width: String.to_integer(fetch_field!(fields, "imWidth", path)),
      im_height: String.to_integer(fetch_field!(fields, "imHeight", path))
    }
  end

  defp fetch_field!(fields, key, path) do
    case fields do
      %{^key => value} -> value
      _missing -> Mix.raise("seqinfo.ini at #{path} is missing #{key}")
    end
  end

  defp load_detections!(path, seqinfo, det_min) do
    parsed =
      path
      |> read!("det/det.txt")
      |> String.split(["\n", "\r\n"], trim: true)
      |> Enum.map(&parse_det_line!/1)

    above_min = Enum.filter(parsed, fn det -> det_min == nil or det.conf >= det_min end)

    kept =
      Enum.flat_map(above_min, fn det ->
        case object(det, seqinfo) do
          nil -> []
          object -> [{det.frame, object}]
        end
      end)

    by_frame =
      Enum.group_by(kept, fn {frame, _object} -> frame end, fn {_frame, object} -> object end)

    stats = %{
      total: length(parsed),
      below_det_min: length(parsed) - length(above_min),
      clamped_out: length(above_min) - length(kept),
      kept: length(kept)
    }

    {by_frame, stats}
  end

  @doc false
  def parse_det_line!(line) do
    case String.split(line, ",") do
      [frame, _id, x, y, w, h, conf | _rest] ->
        %{
          frame: String.to_integer(String.trim(frame)),
          x: parse_number!(x),
          y: parse_number!(y),
          w: parse_number!(w),
          h: parse_number!(h),
          conf: parse_number!(conf)
        }

      _other ->
        Mix.raise("malformed det.txt line: #{inspect(line)}")
    end
  end

  # MOT boxes routinely poke outside the frame; the tracker requires
  # normalized 0..1 ltwh, so clamp to the frame and drop what vanishes.
  @doc false
  def object(det, %{im_width: iw, im_height: ih}) do
    x0 = clamp01(det.x / iw)
    y0 = clamp01(det.y / ih)
    x1 = clamp01((det.x + det.w) / iw)
    y1 = clamp01((det.y + det.h) / ih)

    if x1 > x0 and y1 > y0 do
      %{
        label: "person",
        score: clamp01(det.conf),
        bbox: [x0, y0, x1 - x0, y1 - y0],
        track_id: nil,
        observation_kind: "detected"
      }
    end
  end

  defp clamp01(value), do: value |> max(0.0) |> min(1.0)

  defp parse_number!(string) do
    trimmed = String.trim(string)

    case Float.parse(trimmed) do
      {value, ""} -> value
      _other -> Mix.raise("not a number: #{inspect(string)}")
    end
  end

  defp read!(path, what) do
    case File.read(path) do
      {:ok, content} -> content
      {:error, reason} -> Mix.raise("cannot read #{what} at #{path}: #{inspect(reason)}")
    end
  end

  # -- config echo ------------------------------------------------------------

  defp write_sidecar(out, run) do
    config = %{
      task: "cairn.mot.track",
      git_sha: git_sha(),
      seq: run.seqinfo.name,
      seq_dir: run.seq_dir,
      fps: run.fps,
      seq_length: run.seqinfo.seq_length,
      image_size: [run.seqinfo.im_width, run.seqinfo.im_height],
      det_min: run.det_min,
      detections_total: run.stats.total,
      detections_below_det_min: run.stats.below_det_min,
      detections_clamped_out: run.stats.clamped_out,
      detections_kept: run.stats.kept,
      lines_emitted: run.emitted,
      tracks_minted: run.minted,
      policy: %{run.policy | min_score: run.policy.min_score["default"]}
    }

    sidecar = Path.rootname(out) <> ".config.json"
    File.write!(sidecar, Jason.encode_to_iodata!(config, pretty: true))
  end

  defp git_sha do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _other -> "unknown"
    end
  end
end
