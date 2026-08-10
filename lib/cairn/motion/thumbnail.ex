defmodule Cairn.Motion.Thumbnail do
  @moduledoc """
  A downscaled grayscale copy of one frame's content rectangle — the port of
  `GrayThumb` in `plugins/cairn-detect/src/motion.rs`, **bit-exact** by
  construction.

  The Rust downsample is the one genuinely integer stage of the whole gate:
  truncating box edges (`tx * w / thumb_w`), integer sums of the 256-scaled
  BT.601 luma (`77r + 150g + 29b`, summing to exactly 256 so a grey pixel
  reproduces exactly), a truncating `sum / (count * 256)`. A float resize
  "close enough" to it moves pixels by one grey level either side of the
  threshold and silently changes which frames get inferred — so this module
  reproduces the integer arithmetic instead, and every intermediate is an
  exact BEAM integer.

  Downscaling is the noise filter — sensor grain and blocking average away,
  anything worth inferring on survives — and every source pixel lands in
  exactly one box, so a thumbnail pixel is the mean of the block under it
  rather than a point sample that would alias a moving edge into and out of
  existence between frames.

  The reduction runs on the payload binary directly rather than through Nx
  tensors, deliberately: `Nx.BinaryBackend` prices this stage at ~280 ms per
  416x234 frame (`dot` and `cumulative_sum` at source resolution dominate),
  while a compiled binary walk is ~1.5 ms — and D-C3's point was avoiding a
  native dependency, which a binary comprehension avoids even harder. Nx
  picks up from the thumbnail (`t:t/0` carries a u8 tensor), where the f32
  arithmetic actually lives and 5k-element tensors cost what the research
  budgeted. The box edges depend only on the content geometry, fixed for the
  life of a stream, so they are built once as a `plan/2` and reused per
  frame.
  """

  @max_thumb_w 96

  defstruct [:w, :h, :tensor]

  @typedoc "Luma at the thumbnail geometry: a `{h, w}` u8 tensor."
  @type t :: %__MODULE__{w: pos_integer(), h: pos_integer(), tensor: Nx.Tensor.t()}

  @typedoc "Precomputed box edges and divisors for one content geometry."
  @opaque plan :: map()

  @doc "The thumbnail's `{w, h}`."
  @spec size(t()) :: {pos_integer(), pos_integer()}
  def size(%__MODULE__{w: w, h: h}), do: {w, h}

  @doc """
  Thumbnail geometry for a content rectangle: the same aspect ratio, at most
  #{@max_thumb_w} px wide, never scaled up, and a sliver still has a usable
  row. Integer arithmetic throughout, as the crate's `thumb_size`.
  """
  @spec thumb_size(pos_integer(), pos_integer()) :: {pos_integer(), pos_integer()}
  def thumb_size(w, h) do
    source_w = max(w, 1)
    tw = min(source_w, @max_thumb_w)
    {tw, max(div(h * tw, source_w), 1)}
  end

  @doc """
  The per-geometry constants of the downsample: each thumbnail column as a
  byte-length segment of a source row (the ragged `tx * w / tw` box edges,
  floored, each box at least one source pixel), each thumbnail row as a span
  of source rows, and the `count * 256` divisor per box column.
  """
  @spec plan(pos_integer(), pos_integer()) :: plan()
  def plan(w, h) when is_integer(w) and w > 0 and is_integer(h) and h > 0 do
    {tw, th} = thumb_size(w, h)
    {x_starts, x_stops} = edges(w, tw)
    {y_starts, y_stops} = edges(h, th)

    %{
      w: w,
      h: h,
      tw: tw,
      th: th,
      row_bytes: w * 3,
      # The x edges partition the row exactly (`thumb_size` keeps `tw <= w`),
      # so a row's segments consume it whole — `sum_row/2` matches on the
      # empty rest to insist on it.
      seg_bytes: Enum.zip_with(x_stops, x_starts, fn stop, start -> (stop - start) * 3 end),
      rows: Enum.zip(y_starts, y_stops)
    }
  end

  @doc """
  Box-filter downsample of tightly packed RGB24 rows to the thumbnail size.

  `payload` must be exactly `w * h * 3` bytes of the geometry the plan was
  built for — the same precondition the crate's `from_rgb24` carries, checked
  here because the payload arrives over a pad rather than from the scaler
  that minted it.
  """
  @spec from_rgb24(binary(), plan()) :: t()
  def from_rgb24(payload, %{w: w, h: h} = plan) when is_binary(payload) do
    expected = w * h * 3

    if byte_size(payload) != expected do
      raise ArgumentError,
            "payload is #{byte_size(payload)} bytes, not the #{expected} of " <>
              "#{w}x#{h} packed RGB24"
    end

    rows =
      Enum.map(plan.rows, fn {y0, y1} ->
        sums =
          y0..(y1 - 1)
          |> Enum.map(&sum_row(binary_part(payload, &1 * plan.row_bytes, plan.row_bytes), plan))
          |> sum_columns()

        count = y1 - y0

        Enum.zip_with(sums, plan.seg_bytes, fn sum, seg ->
          # The truncating mean, exactly as the crate: the weights sum to
          # 256, so this is already 0..=255.
          div(sum, div(seg, 3) * count * 256)
        end)
      end)

    # The backend is pinned rather than defaulted: `Cairn.Motion`'s
    # exactness argument is made for `Nx.BinaryBackend`'s arithmetic, and
    # every downstream op inherits this tensor's backend — so a dependency
    # that swaps the global Nx default cannot silently move the measurement.
    %__MODULE__{
      w: plan.tw,
      h: plan.th,
      tensor:
        rows
        |> :erlang.list_to_binary()
        |> Nx.from_binary(:u8, backend: Nx.BinaryBackend)
        |> Nx.reshape({plan.th, plan.tw})
    }
  end

  @doc "Convenience for callers without a cached plan (tests, one-offs)."
  @spec from_rgb24(binary(), pos_integer(), pos_integer()) :: t()
  def from_rgb24(payload, w, h), do: from_rgb24(payload, plan(w, h))

  # One source row's luma totals per thumbnail column.
  defp sum_row(row, plan) do
    {sums, <<>>} =
      Enum.map_reduce(plan.seg_bytes, row, fn seg, rest ->
        <<segment::binary-size(^seg), rest::binary>> = rest
        {sum_segment(segment, 0), rest}
      end)

    sums
  end

  # BT.601 luma scaled by 256, accumulated as plain integers — the same
  # `77r + 150g + 29b` u32 sum the crate takes, without a ceiling to overflow.
  defp sum_segment(<<r, g, b, rest::binary>>, acc),
    do: sum_segment(rest, acc + 77 * r + 150 * g + 29 * b)

  defp sum_segment(<<>>, acc), do: acc

  defp sum_columns([first | rest]),
    do: Enum.reduce(rest, first, fn row, acc -> Enum.zip_with(row, acc, &(&1 + &2)) end)

  # One axis's box edges: box `t` covers `[t*source/target, (t+1)*source/target)`,
  # floored, widened to at least one source pixel — the crate's `.max(x0 + 1)`,
  # inert whenever `target <= source` (always, per `thumb_size`) but kept so the
  # two implementations cannot drift.
  defp edges(source, target) do
    starts = Enum.map(0..(target - 1), &div(&1 * source, target))

    stops =
      Enum.map(0..(target - 1), fn t ->
        max(div((t + 1) * source, target), div(t * source, target) + 1)
      end)

    {starts, stops}
  end
end
