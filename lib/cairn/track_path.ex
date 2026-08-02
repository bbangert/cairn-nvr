defmodule Cairn.TrackPath do
  # Declared before the moduledoc, which interpolates them: a tuning pass that
  # changes a number here must not leave the prose describing the old one.
  @format_version 1

  # Quantized units, so 20 is 0.002 of the frame extent — about 4 px across a
  # 1920-wide frame. The wire granularity is 1, so this suppresses jitter and
  # nothing a viewer could see.
  @keyframe_delta 20
  @max_gap_ms 2_000
  # Precedent: `@max_label_entries` in `Cairn.DetectionAggregator`. At the
  # ~10 obs/s the plugin sustains this is over eight minutes of an unbroken,
  # never-still path — a track that reaches it is a scene artifact, and the
  # earliest samples are the ones a viewer opened the clip for.
  @max_samples_per_track 5_000

  @moduledoc """
  The dense bbox sidecar: one file per event, written next to its clip at the
  path `Cairn.DataDir.trackpath_for_clip/1` derives, holding the box of every
  tagged observation seen while the event was open.

  This module is the format's single source of truth. The reader that draws the
  boxes is a browser, which cannot share this code:
  `assets/js/hooks/track_overlay.js` re-implements the arithmetic below in
  JavaScript. The layout is therefore a contract between two implementations
  rather than an internal detail of one — a change here is a change there — and
  it is written down here because there is nowhere else it could be.
  (`Cairn.Snapshot.clip_seek/2` reads the header too, through `decode/1`, for
  the anchor alone.)

  Per-frame boxes and track identity meet in exactly one place in this system,
  `Cairn.Tracker`'s `tagged` list; every consumer downstream of it sees one or
  the other. The sidecar is that list, kept.

  ## Container

  MessagePack, gzipped. The gzip is at rest rather than at serve time:
  `content-encoding: gzip` lets a route hand the stored bytes over unmodified
  and the browser's own `fetch` unwraps them, so compressing once at write
  costs no reader anything and the disk keeps the saving too.

  ## Format v#{@format_version}

      %{
        "v" => #{@format_version},
        "event_id" => "01J...", "camera_id" => "driveway",
        "truncated" => false,
        "anchor" => %{
          "first_pts" => 1_234, "timescale" => 90_000,
          "drained_span_ms" => 4_800,
          "drain_wall_ms" => 1_700_000_000_000,
          "live_media_ms" => 6_800,
          "live_wall_ms" => 1_700_000_001_700,
          "event_started_ms" => 1_699_999_995_200
        },
        "ts" => [0, 400, 100, ...],
        "tracks" => [
          %{"id" => "01J...", "label" => "person", "truncated" => false,
            "ti" => [0, 1, 2, ...],
            "x" => [1000, 40, -12, ...], "y" => [...], "w" => [...], "h" => [...]}
        ]
      }

  `"truncated"` at the top level is the caller's own flag — the buffer that fed
  `encode/2` hit a global cap and dropped batches. The per-track one is this
  module's: that track had more kept samples than the per-track cap below.
  Both are plain booleans and neither implies the other.

  `"anchor"` is the clip's time-zero as the writer knew it, in two halves that
  pair a media position with a wall clock. The **drain half** — `"first_pts"`,
  `"timescale"`, `"drained_span_ms"`, `"drain_wall_ms"` — is what the extractor
  *kept* of the ring's pre-window when it drained it. The **live half** —
  `"live_media_ms"`, `"live_wall_ms"` — is the position the first fragment
  written from the live stream ends at, against the wall clock at its arrival.
  `"event_started_ms"` belongs to both.

  Both media positions are measured from the same origin: the first
  keyframe-headed fragment the clip holds, which is the t=0 `Cairn.ClipRemux`
  rebases the file to. `Cairn.EventExtractor` writes nothing before that
  fragment precisely so this origin and the file's own agree — a clip that
  started mid-GOP would lose its leading samples to the remux and leave every
  position here late by the span that went missing, with no half able to
  detect it.

  Either half maps an event-relative `"ts"` onto a position in the clip, by the
  same arithmetic:

      clip_seconds = (media_ms + event_started_ms − wall_ms + ts) / 1000

  — a known media position, shifted by where the event's own start falls
  relative to the wall instant that position was paired with.

  A reader tries the live half first and falls back to the drain half, because
  the two pairings are not equally tight. A fragment reaches the extractor once
  it is *complete*, so `"live_wall_ms"` trails the media at `"live_media_ms"`
  by the transport and the demux alone. `"drain_wall_ms"` trails the media at
  `"drained_span_ms"` by that plus however much of the next fragment ffmpeg had
  accumulated and not yet written — up to one `-frag_duration` (~2 s), wherever
  the boundary happened to fall. That surplus is time the drain half does not
  know about, so it places every observation that much too early, which a
  viewer sees as boxes running ahead of what they are drawn around.

  That preference corrects the drain half's surplus and nothing else. It is
  worth saying because the same symptom once had a second cause with a
  different remedy: a clip starting mid-GOP shifted *both* halves by the same
  span, so preferring one over the other changed nothing. That one is fixed at
  the writer (see `Cairn.EventExtractor`), not here.

  `anchor_clip_ms/2` is that preference order for Elixir readers — it is where
  `Cairn.Snapshot.clip_seek/2` sends its anchor rather than choosing a half
  itself; `assets/js/hooks/track_overlay.js` re-implements it. Both require a
  half's
  three fields to be numbers and its media position to be non-negative, and a
  half that fails either is skipped for the one below it.

  Where they part is what counts as an impossible answer, because they know
  different things. `anchor_clip_ms/2` refuses a position before the start of
  the clip and has no opinion about the end: its caller has the file and can
  clamp. The overlay has the `<video>` element, so it refuses a half that puts
  the event's t=0 past the end of the video, and it tolerates up to a second
  before the start — clamping that to zero rather than falling back, since a
  fraction of a second out is still far better than the estimate below it.

  `"first_pts"` and `"timescale"` take no part in either mapping; they are
  carried so a reader can relate the same position to the clip's own media
  clock without re-probing the file.

  The whole map is `nil` when the writer had no anchor to offer, and each field
  is `nil`-able on its own: an event that finalized before any fragment arrived
  live has no live half, a camera whose ring had not filled has no drained
  span, and a file written before either half existed has neither. A consumer
  left with no usable half falls back to a pre-roll estimate of its own —
  `duration − event_seconds` for the event timeline, the *configured*
  pre-window for `Cairn.Snapshot`.

  Neither half is exact. The live one still carries whatever the camera, the
  transport and the demux cost between a frame being exposed and its fragment
  arriving at the extractor — on the order of 100 ms, roughly constant for a
  given setup, and in the same direction (boxes ahead of the subject). Nothing
  corrects for it. If it ever earns a constant, this is where the decision
  belongs, applied in `anchor_clip_ms/2` and mirrored in the overlay, rather
  than tuned separately in each reader.

  ## Coordinates

  Boxes arrive as normalized `[x, y, w, h]` floats and are stored as
  `round(v * 10_000)`. That is lossless, not a size trade-off: the plugin
  rounds every coordinate to four decimals before it reaches the wire
  (`wire_bbox/1` in `plugins/cairn-detect/src/infer/heads.rs`), so a wire value
  has no fifth decimal to lose.

  Every numeric column — `"ts"`, and each track's `"ti"`, `"x"`, `"y"`, `"w"`,
  `"h"` — is delta-encoded: the first element is absolute and each later one is
  the difference from the element before it. A consumer reconstructs a column
  with a running sum and nothing else. `decode/1` deliberately does **not** do
  that (see below).

  ## The shared axis

  `"ts"` is the union of the timestamps of all *kept* samples, sorted ascending
  and de-duplicated, then delta-encoded. Times are milliseconds relative to the
  event's `started_at`, exactly as the caller computed them; this module only
  orders and de-duplicates them.

  A track's `"ti"` column indexes into that axis, so a sample's time is never
  repeated per track. Keyframe suppression skips axis entries — two tracks
  rarely keep the same samples — which is why `"ti"` is an index column rather
  than the `(start, count)` range a contiguous layout could use. Delta encoding
  brings it back down to a small integer per sample.

  Reconstructed, `"ts"` and every `"ti"` are strictly increasing — so every
  delta in them is at least 1. A track carries at most one sample per
  timestamp; should one appear twice at the same millisecond, the sample from
  the earlier batch wins.

  ## Keyframes

  A path is drawn by interpolating between stored samples, so samples that
  interpolation would have produced anyway are not worth storing. Four rules
  decide, per track, walking its samples in time order:

    * the first sample is always kept, and so is the last;
    * a sample whose `stationary` flag differs from the last kept sample's is
      always kept — which aligns the stored path with the
      `became_stationary` / `started_moving` moments in the track index for
      free, without sharing a constant with the tracker's own stillness
      heuristic (`@stationary_iou`, which is a sustained-motion classifier
      gated on `stationary_after_ms`, not a per-sample jitter filter);
    * otherwise the sample is kept only if some quantized coordinate moved at
      least `@keyframe_delta` (#{@keyframe_delta}, i.e. 0.2 % of the frame
      extent) from the last kept sample;
    * and it is kept regardless if more than `@max_gap_ms` (#{@max_gap_ms} ms)
      have passed since the last kept sample, so suppression alone never leaves
      a viewer interpolating across more than `@max_gap_ms`. It bounds only the
      gaps this selection creates: the rule can force a keeper where a sample
      exists, not conjure one out of a silence, so a stretch nobody observed
      (a stalled plugin, an empty tagged list, the caller's own cap) is still
      two adjacent samples with a straight line between them.

  A per-track cap of `@max_samples_per_track` (#{@max_samples_per_track})
  applies after that selection. It keeps the earliest samples and sets the
  track's `"truncated"` flag; the "last sample is always kept" rule is the one
  casualty, since the tail is what a cap drops. Nothing else in the format is
  affected.

  ## What v#{@format_version} does not carry

  No per-sample score: the track index row's `best_score` is the number the UI
  shows, and a fifth column per sample would cost every reader for something
  nothing draws. No per-sample `stationary` either — it decides keyframes here
  and is then dropped, because a track's stationary transitions are already
  rows in `Cairn.Tracks.TrackEvent`, at one row per flip instead of one value
  per sample. Predicted boxes are in the path like any other sample and are not
  marked: they are what keeps a path continuous through a detection miss, and a
  reader that could tell them apart would only be tempted to break the line.
  """

  @typedoc "Normalized `[x, y, w, h]`, each 0..1, as validated on the wire."
  @type bbox :: [number()]

  @typedoc "One tagged observation: `Cairn.Tracker` identity plus its box."
  @type box_entry ::
          {object_id :: String.t(), label :: String.t(), bbox(), stationary :: boolean()}

  @typedoc "One observation batch: its time in ms since the event's `started_at`."
  @type entry :: {t_ms :: integer(), [box_entry()]}

  @typedoc """
  Everything in the file that is not a path.

  `:event_id` and `:camera_id` are required; `:truncated` defaults to `false`
  and `:anchor` to `nil`. Anchor fields are passed through as given, `nil`
  included.
  """
  @type header :: %{
          required(:event_id) => String.t(),
          required(:camera_id) => String.t(),
          optional(:truncated) => boolean(),
          optional(:anchor) => map() | nil
        }

  @doc """
  Encodes a header and the extractor's buffered batches into sidecar bytes.

  `entries` arrive **newest first** — the shape a `handle_cast` accumulator
  built by prepending has — and are reversed here, so a caller never pays for
  an append. Their order is a convenience, not a contract: samples are sorted
  by time per track regardless.
  """
  @spec encode(header(), [entry()]) :: binary()
  def encode(header, entries) do
    tracks =
      entries
      |> Enum.reverse()
      |> collect()
      |> Enum.map(&select_keyframes/1)

    axis = build_axis(tracks)
    index = axis |> Enum.with_index() |> Map.new()

    %{
      "v" => @format_version,
      "event_id" => Map.fetch!(header, :event_id),
      "camera_id" => Map.fetch!(header, :camera_id),
      "truncated" => Map.get(header, :truncated, false) == true,
      "anchor" => anchor(Map.get(header, :anchor)),
      "ts" => deltas(axis),
      "tracks" => Enum.map(tracks, &columns(&1, index))
    }
    |> Msgpax.pack!()
    |> :zlib.gzip()
  end

  @doc """
  Reads sidecar bytes back into the map `encode/2` wrote.

  This is the container's inverse and nothing more: the returned map is
  delta-encoded and quantized exactly as stored. Un-deltaing and dividing by
  10_000 is the consumer's job, and leaving it there is what keeps this
  function honest as the thing a test asserts the on-disk layout with.

  Fails as `{:error, :not_gzipped}` or `{:error, :malformed}` — a truncated
  write, a file that is not a sidecar at all, or a payload that is not a plain
  map (a msgpack ext at the top level decodes to a struct and is refused here).

  Trusts its input to be a file this host wrote: `:zlib.gunzip/1` inflates
  without a size ceiling, so a caller decoding bytes from anywhere else — a
  restored backup, an imported archive, an upload — must size-check or cap the
  inflate itself before calling this.
  """
  @spec decode(binary()) :: {:ok, map()} | {:error, :not_gzipped | :malformed}
  def decode(binary) when is_binary(binary) do
    case gunzip(binary) do
      {:ok, plain} -> unpack(plain)
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Places an event-relative time on the clip's own timeline, from a decoded
  anchor: `{:ok, clip_ms}`, or `:error` when the anchor cannot place it.

  `anchor` is the `"anchor"` value `decode/1` returns — string keys, `nil`
  included — and `t_ms` is a time in the same milliseconds-since-`started_at`
  the `"ts"` column is in. Passing `0` yields where the event's t=0 sits inside
  the clip, which is the form a reader stepping through many samples wants.

  The live half is preferred over the drain half and the reasons are in the
  moduledoc's anchor section; each half is used only if its three fields are
  numbers, its media position is not negative, and the position it produces is
  not before the start of the clip. A half that fails any of those is skipped,
  so a live half spoiled by an ffmpeg respawn (`pts` restarts, the difference
  goes negative) still leaves the drain half to answer.

  `:error` is the caller's cue to use whatever pre-roll estimate it has; it is
  never a reason to refuse to draw or to seek. Nothing here raises: the anchor
  arrives off disk, so a value of the wrong type anywhere in it — or in `t_ms`,
  which the spec asks for a number of and this does not trust to be one — is
  `:error` like any other unusable half.
  """
  @spec anchor_clip_ms(map() | nil, number()) :: {:ok, number()} | :error
  def anchor_clip_ms(anchor, t_ms)

  def anchor_clip_ms(%{} = anchor, t_ms) when is_number(t_ms) do
    started_ms = Map.get(anchor, "event_started_ms")

    with :error <-
           place(
             Map.get(anchor, "live_media_ms"),
             Map.get(anchor, "live_wall_ms"),
             started_ms,
             t_ms
           ) do
      place(
        Map.get(anchor, "drained_span_ms"),
        Map.get(anchor, "drain_wall_ms"),
        started_ms,
        t_ms
      )
    end
  end

  def anchor_clip_ms(_no_anchor, _t_ms), do: :error

  defp place(media_ms, wall_ms, started_ms, t_ms)
       when is_number(media_ms) and media_ms >= 0 and is_number(wall_ms) and is_number(started_ms) do
    case media_ms + started_ms - wall_ms + t_ms do
      clip_ms when clip_ms >= 0 -> {:ok, clip_ms}
      _before_the_clip -> :error
    end
  end

  defp place(_media_ms, _wall_ms, _started_ms, _t_ms), do: :error

  defp gunzip(binary) do
    {:ok, :zlib.gunzip(binary)}
  rescue
    # `:zlib.gunzip/1` raises `:data_error` on anything that is not a complete
    # gzip stream, a file cut short by a full disk included. The rescue wraps
    # this call alone so that a failure to unpack cannot be reported as one.
    ErlangError -> {:error, :not_gzipped}
  end

  # `not is_struct/1` is load-bearing, not belt and braces: `%{}` matches any
  # struct, and a top-level msgpack ext unpacks to `%Msgpax.Ext{}` (or a
  # `DateTime`, for reserved type −1). Without it a crafted file returns
  # `{:ok, struct}` from the clause whose whole job is to have rejected it.
  defp unpack(plain) do
    case Msgpax.unpack(plain) do
      {:ok, map} when is_map(map) and not is_struct(map) -> {:ok, map}
      _not_a_sidecar -> {:error, :malformed}
    end
  end

  # -- collection -------------------------------------------------------------

  # Groups the flattened batches by object, keeping first-appearance order for
  # the tracks and time order within each. A track's label is the one it
  # carried on its first sample: the tracker re-reads the label off every
  # observation, so a wavering classifier could otherwise rename a path
  # mid-file.
  defp collect(entries) do
    {by_id, order} =
      Enum.reduce(entries, {%{}, []}, fn {t_ms, boxes}, acc ->
        Enum.reduce(boxes, acc, &put_sample(&1, t_ms, &2))
      end)

    for id <- Enum.reverse(order) do
      {label, samples} = Map.fetch!(by_id, id)

      samples =
        samples
        |> Enum.reverse()
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.dedup_by(&elem(&1, 0))

      {id, label, samples}
    end
  end

  defp put_sample({object_id, label, bbox, stationary}, t_ms, {by_id, order}) do
    sample = {t_ms, quantize(bbox), stationary == true}

    case by_id do
      %{^object_id => {label0, samples}} ->
        {Map.put(by_id, object_id, {label0, [sample | samples]}), order}

      _first_sighting ->
        {Map.put(by_id, object_id, {label, [sample]}), [object_id | order]}
    end
  end

  defp quantize([x, y, w, h]) do
    {round(x * 10_000), round(y * 10_000), round(w * 10_000), round(h * 10_000)}
  end

  # -- keyframes --------------------------------------------------------------

  # `Enum.split/2` rather than a `length/1` test and a separate take: the
  # overflow it hands back answers "was this truncated" in the same pass that
  # produces the survivors.
  defp select_keyframes({id, label, samples}) do
    case samples |> keep() |> Enum.split(@max_samples_per_track) do
      {kept, []} -> {id, label, kept, false}
      {kept, _dropped} -> {id, label, kept, true}
    end
  end

  defp keep([]), do: []
  defp keep([first | rest]), do: keep(rest, first, [first])

  defp keep([], _last_kept, acc), do: Enum.reverse(acc)
  # The track's last sample, kept whatever the rules would have said. This
  # clause has to stay above the general one: it is the rule, not an
  # optimization of it.
  defp keep([last], _last_kept, acc), do: Enum.reverse([last | acc])

  defp keep([sample | rest], last_kept, acc) do
    if keep?(sample, last_kept) do
      keep(rest, sample, [sample | acc])
    else
      keep(rest, last_kept, acc)
    end
  end

  defp keep?({t, coords, stationary}, {t0, coords0, stationary0}) do
    stationary != stationary0 or t - t0 > @max_gap_ms or moved?(coords, coords0)
  end

  defp moved?({x, y, w, h}, {x0, y0, w0, h0}) do
    abs(x - x0) >= @keyframe_delta or abs(y - y0) >= @keyframe_delta or
      abs(w - w0) >= @keyframe_delta or abs(h - h0) >= @keyframe_delta
  end

  # -- columns ----------------------------------------------------------------

  defp build_axis(tracks) do
    tracks
    |> Enum.flat_map(fn {_id, _label, samples, _truncated} ->
      Enum.map(samples, &elem(&1, 0))
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp columns({id, label, samples, truncated}, index) do
    %{
      "id" => id,
      "label" => label,
      "truncated" => truncated,
      "ti" => samples |> Enum.map(&Map.fetch!(index, elem(&1, 0))) |> deltas(),
      "x" => coord_column(samples, 0),
      "y" => coord_column(samples, 1),
      "w" => coord_column(samples, 2),
      "h" => coord_column(samples, 3)
    }
  end

  defp coord_column(samples, pos) do
    samples |> Enum.map(&elem(elem(&1, 1), pos)) |> deltas()
  end

  # First element absolute, the rest differences from their predecessor.
  defp deltas([]), do: []

  defp deltas([first | rest]) do
    {tail, _last} = Enum.map_reduce(rest, first, fn v, prev -> {v - prev, v} end)
    [first | tail]
  end

  # Every field is read with `Map.get/2`: a caller that could only capture some
  # of the anchor writes `nil` for the rest rather than no anchor at all, which
  # is what lets `anchor_clip_ms/2` fall from a half that is missing to one that
  # is there. A sidecar written before a field existed reads the same way.
  defp anchor(nil), do: nil

  defp anchor(%{} = fields) do
    %{
      "first_pts" => Map.get(fields, :first_pts),
      "timescale" => Map.get(fields, :timescale),
      "drained_span_ms" => Map.get(fields, :drained_span_ms),
      "drain_wall_ms" => Map.get(fields, :drain_wall_ms),
      "live_media_ms" => Map.get(fields, :live_media_ms),
      "live_wall_ms" => Map.get(fields, :live_wall_ms),
      "event_started_ms" => Map.get(fields, :event_started_ms)
    }
  end
end
