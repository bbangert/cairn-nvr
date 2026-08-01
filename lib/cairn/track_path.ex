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

  `"anchor"` is the clip's time-zero as the writer knew it: the pts and
  timescale the clip's first fragment carried, the media span of the drained
  pre-roll, and the wall clock at the instant that drain returned.

  Three of those map an event-relative `"ts"` onto a position in the clip, and
  are the three every reader of the anchor uses — the browser overlay, and
  `Cairn.Snapshot.clip_seek/2` for the poster frame's own `ts`:

      clip_seconds = (drained_span_ms + event_started_ms − drain_wall_ms + ts) / 1000

  — the drained pre-roll's media span, shifted by where the event's own start
  falls relative to the instant the drain returned. `"first_pts"` and
  `"timescale"` take no part in it; they are carried so a reader can relate the
  same position to the clip's own media clock without re-probing the file.

  The whole map is `nil` when the writer had no anchor to offer, and each field
  is `nil`-able on its own; a consumer that finds one of the three missing falls
  back to a pre-roll estimate of its own — `duration − event_seconds` for the
  event timeline, the *configured* pre-window for `Cairn.Snapshot`.

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
  # is what lets a reader mix a media-domain field with a wall-clock fallback.
  defp anchor(nil), do: nil

  defp anchor(%{} = fields) do
    %{
      "first_pts" => Map.get(fields, :first_pts),
      "timescale" => Map.get(fields, :timescale),
      "drained_span_ms" => Map.get(fields, :drained_span_ms),
      "drain_wall_ms" => Map.get(fields, :drain_wall_ms),
      "event_started_ms" => Map.get(fields, :event_started_ms)
    }
  end
end
