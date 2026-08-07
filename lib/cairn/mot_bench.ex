defmodule Cairn.MotBench do
  @moduledoc """
  The tracker-driving core the MOT harness mix tasks share.

  Two ingestion modes feed one loop: `mix cairn.mot.track` builds frames
  from a sequence's public `det.txt` (tracker-only mode — no pixels, no
  plugin), and `mix cairn.mot.ndjson` builds them from a captured
  cairn-detect stdout run (end-to-end mode — real detector, real
  embeddings, decoded through the real `Cairn.PluginProtocol`). Both emit
  MOT prediction lines plus a config-echo sidecar, and both canonicalize
  track identity the same way: ULIDs are nondeterministic, so output IDs
  are first-seen ordinals and two runs over the same input are
  byte-identical.
  """

  alias Cairn.{Observation, Tracker}

  @camera_id "mot"

  @doc """
  Drives `Cairn.Tracker` over `frames` — `{frame_index, at_ms, objects}`
  in ascending order — and returns `{lines_iodata, emitted, minted}`.

  Empty object lists are real frames: the tracker is called for them, so
  coasting advances exactly as it would live.
  """
  @spec drive(Enumerable.t(), map(), Tracker.policy()) ::
          {iodata(), non_neg_integer(), non_neg_integer()}
  def drive(frames, seqinfo, policy) do
    initial = {Tracker.new(), %{ids: %{}, next: 1}, [], 0}

    {_tracker, canon, lines, emitted} =
      Enum.reduce(frames, initial, fn {frame, at_ms, objects}, {tracker, canon, lines, emitted} ->
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

  @doc """
  The frame stream for `drive/3` from an already-decoded observation: the
  end-to-end mode's mapping of a plugin line onto the gt frame grid.
  Media time carries both clocks — `at_ms` for the tracker and the
  1-indexed native-rate frame the score will be read against.
  """
  @spec frame_for(Observation.t(), number()) :: {pos_integer(), integer()}
  def frame_for(%Observation{media_ms: media_ms}, fps) when is_number(media_ms) do
    {max(round(media_ms / 1_000 * fps) + 1, 1), round(media_ms)}
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

  # `observed_at` is reporting data, not a clock the tracker decides on
  # (same convention as the golden harness).
  defp wall(at_ms), do: DateTime.add(~U[2026-07-26 12:00:00Z], at_ms, :millisecond)

  @doc """
  Writes the prediction file atomically: tmp then rename, so a killed run
  can never leave a partial file a resume would trust — the lesson the
  phase-2 harness learned the measured way.
  """
  @spec write_pred!(Path.t(), iodata()) :: :ok
  def write_pred!(out, lines) do
    File.mkdir_p!(Path.dirname(out))
    tmp = out <> ".part"
    File.write!(tmp, lines)
    File.rename!(tmp, out)
  end

  @doc "The policy map both tasks build from their CLI flags — one spelling."
  @spec policy(keyword()) :: Tracker.policy()
  def policy(opts) do
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

  @doc "Writes the config-echo sidecar next to `out` (house rule: re-derivable)."
  @spec write_sidecar(Path.t(), map()) :: :ok
  def write_sidecar(out, config) do
    config =
      Map.merge(config, %{
        git_sha: git_sha(),
        policy: %{config.policy | min_score: config.policy.min_score["default"]}
      })

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
