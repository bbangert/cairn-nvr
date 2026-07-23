defmodule Cairn.MP4.Demuxer do
  @moduledoc """
  Pure, incremental fmp4 byte-stream parser.

  Feed arbitrary chunks with `push/2`; it emits:

    * `{:init, %{data: binary, codec: String.t() | nil, timescale: pos_integer}}`
      once the init segment (`ftyp` + `moov`) is complete. `codec` is the
      RFC 6381 string (e.g. `"avc1.64001f"`) extracted from `avcC`.
    * `{:fragment, %Cairn.Fragment{}}` for each complete `moof` + `mdat`
      pair, with `pts` from `tfdt` and duration from `trun`/`tfhd`.
    * `{:error, reason}` on stream desync (buffer is dropped; the caller
      should restart the producer and a fresh demuxer).

  Any chunking of the same byte stream yields the same events.
  """

  import Bitwise, only: [&&&: 2]

  alias Cairn.Fragment

  # An mdat can be a whole GOP; anything beyond this is a desynced stream.
  @max_box_bytes 256 * 1024 * 1024

  defstruct camera_id: nil,
            buffer: <<>>,
            seq: 0,
            ftyp: nil,
            timescale: 90_000,
            codec: nil,
            init_sent: false,
            default_sample_duration: nil,
            pending_moof: nil

  @type t :: %__MODULE__{}
  @type event ::
          {:init, %{data: binary(), codec: String.t() | nil, timescale: pos_integer()}}
          | {:fragment, Fragment.t()}
          | {:error, term()}

  @spec new(String.t()) :: t()
  def new(camera_id), do: %__MODULE__{camera_id: camera_id}

  @spec push(t(), binary()) :: {t(), [event()]}
  def push(%__MODULE__{} = d, data) when is_binary(data) do
    parse(%{d | buffer: d.buffer <> data}, [])
  end

  defp parse(d, events) do
    case next_box(d.buffer) do
      :more ->
        {d, Enum.reverse(events)}

      {:error, reason} ->
        {%{d | buffer: <<>>, pending_moof: nil}, Enum.reverse([{:error, reason} | events])}

      {:ok, type, box_bytes, rest} ->
        {d, events} = handle_box(%{d | buffer: rest}, type, box_bytes, events)
        parse(d, events)
    end
  end

  # -- box framing ------------------------------------------------------------

  defp next_box(<<1::32, type::binary-size(4), largesize::64, _::binary>> = buf) do
    framed(buf, type, largesize)
  end

  defp next_box(<<1::32, _::binary>>), do: :more

  defp next_box(<<size::32, type::binary-size(4), _::binary>> = buf) when size >= 8 do
    framed(buf, type, size)
  end

  defp next_box(<<size::32, _type::binary-size(4), _::binary>>) do
    {:error, {:bad_box_size, size}}
  end

  defp next_box(_buf), do: :more

  defp framed(_buf, _type, size) when size > @max_box_bytes, do: {:error, {:box_too_large, size}}

  defp framed(buf, type, size) do
    case buf do
      <<box_bytes::binary-size(^size), rest::binary>> -> {:ok, type, box_bytes, rest}
      _ -> :more
    end
  end

  # -- box dispatch -----------------------------------------------------------

  defp handle_box(d, "ftyp", box_bytes, events) do
    {%{d | ftyp: box_bytes}, events}
  end

  defp handle_box(d, "moov", box_bytes, events) do
    moov = payload(box_bytes)
    {timescale, codec, default_dur} = parse_moov(moov)
    init = (d.ftyp || <<>>) <> box_bytes

    d = %{
      d
      | timescale: timescale || d.timescale,
        codec: codec,
        default_sample_duration: default_dur,
        init_sent: true
    }

    event = {:init, %{data: init, codec: codec, timescale: d.timescale}}
    {d, [event | events]}
  end

  defp handle_box(d, "moof", box_bytes, events) do
    {pts, duration} = parse_moof(payload(box_bytes), d.default_sample_duration)
    {%{d | pending_moof: {box_bytes, pts, duration}}, events}
  end

  defp handle_box(%{pending_moof: nil} = d, "mdat", _box_bytes, events) do
    # mdat without a preceding moof (e.g. joined mid-stream): drop
    {d, events}
  end

  defp handle_box(%{pending_moof: {moof, pts, duration}} = d, "mdat", box_bytes, events) do
    frag = %Fragment{
      camera_id: d.camera_id,
      seq: d.seq,
      pts: pts,
      duration_ms: div(duration * 1000, max(d.timescale, 1)),
      timescale: d.timescale,
      data: moof <> box_bytes
    }

    {%{d | seq: d.seq + 1, pending_moof: nil}, [{:fragment, frag} | events]}
  end

  # sidx / styp / free / anything else between fragments
  defp handle_box(d, _type, _box_bytes, events), do: {d, events}

  defp payload(<<1::32, _type::binary-size(4), _largesize::64, rest::binary>>), do: rest
  defp payload(<<_size::32, _type::binary-size(4), rest::binary>>), do: rest

  # -- moov parsing -----------------------------------------------------------

  # Finds the video trak (the one with an avcC), returning
  # {timescale, codec_string, default_sample_duration}.
  defp parse_moov(moov) do
    traks = for {"trak", body} <- children_of(moov), do: body

    video =
      Enum.find_value(traks, fn trak ->
        with mdia when is_binary(mdia) <- child(trak, "mdia"),
             minf when is_binary(minf) <- child(mdia, "minf"),
             stbl when is_binary(stbl) <- child(minf, "stbl"),
             stsd when is_binary(stsd) <- child(stbl, "stsd"),
             codec when not is_nil(codec) <- codec_from_stsd(stsd) do
          {mdhd_timescale(child(mdia, "mdhd")), codec}
        else
          _ -> nil
        end
      end)

    default_dur = trex_default_duration(child(moov, "mvex"))

    case video do
      {timescale, codec} -> {timescale, codec, default_dur}
      nil -> {first_timescale(traks), nil, default_dur}
    end
  end

  defp first_timescale([]), do: nil

  defp first_timescale([trak | rest]) do
    with mdia when is_binary(mdia) <- child(trak, "mdia"),
         ts when is_integer(ts) <- mdhd_timescale(child(mdia, "mdhd")) do
      ts
    else
      _ -> first_timescale(rest)
    end
  end

  defp mdhd_timescale(<<0::8, _flags::24, _c::32, _m::32, timescale::32, _::binary>>),
    do: timescale

  defp mdhd_timescale(<<1::8, _flags::24, _c::64, _m::64, timescale::32, _::binary>>),
    do: timescale

  defp mdhd_timescale(_), do: nil

  defp codec_from_stsd(<<_verflags::32, _count::32, entries::binary>>) do
    Enum.find_value(children_of(entries), fn {type, body} ->
      sample_entry_codec(type, body)
    end)
  end

  defp codec_from_stsd(_), do: nil

  # avc1/avc3 visual sample entry: 78 bytes of fixed fields, then sub-boxes
  defp sample_entry_codec(type, <<_fixed::binary-size(78), boxes::binary>>)
       when type in ["avc1", "avc3"] do
    Enum.find_value(children_of(boxes), fn
      {"avcC", <<1, profile, compat, level, _::binary>>} ->
        "avc1." <> Base.encode16(<<profile, compat, level>>, case: :lower)

      _ ->
        nil
    end)
  end

  defp sample_entry_codec(_type, _body), do: nil

  defp trex_default_duration(nil), do: nil

  defp trex_default_duration(mvex) do
    case child(mvex, "trex") do
      <<_verflags::32, _track_id::32, _sdi::32, duration::32, _::binary>> when duration > 0 ->
        duration

      _ ->
        nil
    end
  end

  # -- moof parsing -----------------------------------------------------------

  defp parse_moof(moof, moov_default_dur) do
    case child(moof, "traf") do
      nil ->
        {0, 0}

      traf ->
        pts = tfdt_time(child(traf, "tfdt"))
        tfhd_default = tfhd_default_duration(child(traf, "tfhd"))
        duration = trun_duration(child(traf, "trun"), tfhd_default || moov_default_dur)
        {pts, duration}
    end
  end

  defp tfdt_time(<<0::8, _flags::24, time::32, _::binary>>), do: time
  defp tfdt_time(<<1::8, _flags::24, time::64, _::binary>>), do: time
  defp tfdt_time(_), do: 0

  defp tfhd_default_duration(<<_version::8, flags::24, _track_id::32, rest::binary>>) do
    # optional fields, in order, gated by flags
    rest = if (flags &&& 0x000001) != 0, do: skip(rest, 8), else: rest
    rest = if (flags &&& 0x000002) != 0, do: skip(rest, 4), else: rest

    if (flags &&& 0x000008) != 0 do
      case rest do
        <<duration::32, _::binary>> -> duration
        _ -> nil
      end
    end
  end

  defp tfhd_default_duration(_), do: nil

  defp trun_duration(<<_version::8, flags::24, sample_count::32, rest::binary>>, default_dur) do
    rest = if (flags &&& 0x000001) != 0, do: skip(rest, 4), else: rest
    rest = if (flags &&& 0x000004) != 0, do: skip(rest, 4), else: rest

    if (flags &&& 0x000100) != 0 do
      stride = 4 * count_set_flags(flags, [0x000100, 0x000200, 0x000400, 0x000800])
      sum_sample_durations(rest, sample_count, stride - 4, 0)
    else
      sample_count * (default_dur || 0)
    end
  end

  defp trun_duration(_, _default), do: 0

  defp sum_sample_durations(_rest, 0, _skip_len, acc), do: acc

  defp sum_sample_durations(rest, n, skip_len, acc) do
    case rest do
      <<duration::32, _skipped::binary-size(^skip_len), more::binary>> ->
        sum_sample_durations(more, n - 1, skip_len, acc + duration)

      _ ->
        acc
    end
  end

  defp count_set_flags(flags, masks), do: Enum.count(masks, &((flags &&& &1) != 0))

  defp skip(bin, n) do
    case bin do
      <<_::binary-size(^n), rest::binary>> -> rest
      _ -> <<>>
    end
  end

  # -- generic container walking ---------------------------------------------

  defp child(nil, _type), do: nil

  defp child(container, type) do
    Enum.find_value(children_of(container), fn
      {^type, body} -> body
      _ -> nil
    end)
  end

  defp children_of(bin, acc \\ [])

  defp children_of(<<1::32, type::binary-size(4), largesize::64, _::binary>> = bin, acc)
       when largesize >= 16 do
    take_child(bin, type, largesize - 16, 16, acc)
  end

  defp children_of(<<size::32, type::binary-size(4), _::binary>> = bin, acc) when size >= 8 do
    take_child(bin, type, size - 8, 8, acc)
  end

  defp children_of(_bin, acc), do: Enum.reverse(acc)

  defp take_child(bin, type, body_size, header, acc) do
    case bin do
      <<_::binary-size(^header), body::binary-size(^body_size), rest::binary>> ->
        children_of(rest, [{type, body} | acc])

      _ ->
        Enum.reverse(acc)
    end
  end
end
