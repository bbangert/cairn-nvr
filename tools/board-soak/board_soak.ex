defmodule Cairn.BoardSoak do
  @moduledoc """
  Spike 0.5 re-run, in-VM: drives `Cairn.Native` and `CairnOrt` directly, with
  no Membrane, no `Cairn.Native.Host`, nothing supervised — because what this
  measures is whether the BEAM itself survives sustained QNN inference, and a
  host or a pipeline between this code and the NIFs would hide a crash behind
  a restart. Spike 0.5 asked the same question of the out-of-process plugin
  binary; this is the in-VM half of that comparison.

  Compiled with `elixirc`, not `mix` — the board VM has no release, no
  application tree, no `Logger`. Only `lib/cairn_ort.ex`, `lib/cairn/native.ex`
  and `lib/cairn/native/config.ex` are on its path, so nothing here may
  reference any other `Cairn.*` module; `Cairn.Native.Config.normalize/1` and
  `.stream_params/1` are used for config, since both already enforce the
  crate's exact key sets and this module has no reason to duplicate that.

  A `{:error, _}` from any NIF call is data, not a reason to stop: a soak that
  gives up on its first decode or model error measures nothing.
  """

  # `push_frame/4`'s contract (`CairnOrt`'s moduledoc, `Cairn.Pipeline.Inference`):
  # the crate rescales to 90 kHz itself, and the packed clip's own pts are
  # already ticks on that clock.
  @time_base {1, 90_000}

  # Frame-application progress, not model-latency SLOs: 30 s is often enough to
  # catch a wedge without flooding the ssh log a soak of hours runs under.
  @progress_interval_ms 30_000

  @defaults %{
    model: "/data/cairn-bench/yolox_nano-qdq.onnx",
    labels: "/data/cairn-bench/coco.names",
    backend: "qnn",
    qnn_library: "/data/cairn-bench/libonnxruntime_providers_qnn.so",
    clip: nil,
    seconds: 300,
    streams: 1,
    sample_fps: 5,
    decoder: "auto",
    # The packed clip carries pts and bytes, not geometry, so the source size a
    # hardware decoder needs at open is told to the harness rather than read.
    source_width: nil,
    source_height: nil,
    # Convert on every access unit by default — the model path is what this
    # harness was built to soak. Raise it to emulate a `sample_fps` gate and to
    # separate decode from conversion in the timing.
    sample_every: 1
  }

  @doc """
  Run the soak. `opts` is a map or keyword list; any key left out reads
  `BOARD_SOAK_<KEY>` from the environment, then this module's default.
  """
  @spec run(map() | keyword()) :: :ok | {:error, term()}
  def run(opts \\ []) do
    opts = options(opts)
    announce(opts)

    with :ok <- validate_source(opts),
         :ok <- check_available() do
      with_engine(opts)
    end
  end

  # Same rule (and the same bound) as `Cairn.Native.Host.source_dims/1`: a
  # negative or half-set pair from the env would not reach the crate's own
  # validation — rustler's `Option<usize>` decode raises `badarg` first, and a
  # soak that crashes on its config measures nothing.
  defp validate_source(%{source_width: nil, source_height: nil}), do: :ok

  defp validate_source(%{source_width: w, source_height: h})
       when is_integer(w) and is_integer(h) and w > 0 and h > 0 and
              w <= 2_147_483_647 and h <= 2_147_483_647,
       do: :ok

  defp validate_source(%{source_width: w, source_height: h}) do
    IO.puts(
      "board-soak: refusing to run — BOARD_SOAK_SOURCE_WIDTH/HEIGHT must be a " <>
        "positive pair within i32 or absent on both axes, got #{inspect(w)}x#{inspect(h)}"
    )

    {:error, :bad_source}
  end

  defp with_engine(opts) do
    with {:ok, config} <- build_config(opts),
         {:ok, engine} <- CairnOrt.init(config),
         spec = CairnOrt.engine_spec(engine),
         {:ok, clip} <- read_clip(opts.clip) do
      IO.puts(
        "board-soak: engine ready — input #{spec.width}x#{spec.height} #{spec.encoding}, " <>
          "clip is #{length(clip)} access units"
      )

      results =
        1..opts.streams
        |> Enum.map(&Task.async(fn -> run_stream(engine, spec, config, opts, &1, clip) end))
        |> Task.await_many(:infinity)

      summarize(results)
      :ok
    else
      {:error, reason} ->
        IO.puts("board-soak: refusing to run — #{inspect(reason)}")
        {:error, reason}
    end
  end

  # A missing library must not read as a clean soak — silently skipping to
  # "0 errors" would be the one failure mode this harness exists to catch.
  defp check_available do
    cond do
      not Cairn.Native.available?() ->
        IO.puts("board-soak: cairn-native did not load: #{inspect(Cairn.Native.load_error())}")
        {:error, :native_unavailable}

      not CairnOrt.available?() ->
        IO.puts("board-soak: cairn-ort did not load: #{inspect(CairnOrt.load_error())}")
        {:error, :ort_unavailable}

      true ->
        :ok
    end
  end

  defp build_config(opts) do
    Cairn.Native.Config.normalize(%{
      model: opts.model,
      backend: opts.backend,
      labels: opts.labels,
      decoder: opts.decoder,
      sample_fps: opts.sample_fps,
      qnn: %{library: opts.qnn_library}
    })
  end

  # -- one stream ---------------------------------------------------------

  defp run_stream(engine, spec, config, opts, index, clip) do
    label = "stream-#{index}"

    with {:ok, stream_params} <- Cairn.Native.Config.stream_params(%{}),
         {:ok, stream_ref} <- CairnOrt.open_stream(engine, label, stream_params),
         params = decode_params(spec, config, opts),
         {:ok, decoder_ref} <- Cairn.Native.open_decoder(label, params) do
      t0 = now_ms()

      stats =
        feed(
          decoder_ref,
          stream_ref,
          clip,
          clip,
          t0 + opts.seconds * 1000,
          init_stats(t0, opts.sample_every),
          label
        )

      close(CairnOrt, :close_stream, stream_ref, label)
      close(Cairn.Native, :close_decoder, decoder_ref, label)
      report(label, stats)
      stats
    else
      {:error, reason} ->
        IO.puts("board-soak: #{label} did not open: #{inspect(reason)}")
        init_stats(now_ms())
    end
  end

  # The one place the two libraries meet, same as `Cairn.Native.Host`'s decode-params assembly:
  # the engine's resolved input spec becomes the decoder's params, plus the
  # decode-side knobs (`decoder`, `sample_fps`) that live on the model config.
  defp decode_params(spec, config, opts) do
    %{
      decoder: config.decoder,
      width: spec.width,
      height: spec.height,
      encoding: spec.encoding,
      resize: spec.resize,
      resize_pad: spec.resize_pad,
      source_width: opts.source_width,
      source_height: opts.source_height,
      motion_json: nil,
      sample_fps: config.sample_fps
    }
  end

  defp close(module, fun, ref, label) do
    case apply(module, fun, [ref]) do
      {:ok, _} -> :ok
      {:error, reason} -> IO.puts("board-soak: #{label} #{fun} failed: #{inspect(reason)}")
    end
  end

  # -- feeding --------------------------------------------------------------

  # Cycles the clip rather than pacing to its pts: this harness measures the
  # native path back to back, not wall-clock rate. `sample_every` decides how
  # often `decode_au/4` is asked to convert — every access unit is decoded
  # either way, because a stateful decoder needs its references, so the two
  # cases isolate what conversion costs on top of decode.
  defp feed(decoder_ref, stream_ref, [], clip, deadline, stats, label),
    do: feed(decoder_ref, stream_ref, clip, clip, deadline, stats, label)

  defp feed(decoder_ref, stream_ref, [{au, pts} | rest], clip, deadline, stats, label) do
    now = now_ms()

    if now >= deadline do
      stats
    else
      stats
      |> feed_one(decoder_ref, stream_ref, au, pts)
      |> maybe_progress(label, now)
      |> then(&feed(decoder_ref, stream_ref, rest, clip, deadline, &1, label))
    end
  end

  defp feed_one(stats, decoder_ref, stream_ref, au, pts) do
    sample = rem(stats.aus, stats.sample_every) == 0

    started = System.monotonic_time(:microsecond)
    result = Cairn.Native.decode_au(decoder_ref, au, pts, sample)
    decode_us = System.monotonic_time(:microsecond) - started

    stats = decode_timing(stats, sample, decode_us)

    case result do
      {:ok, {_completed, nil}} ->
        bump(stats, :aus)

      {:ok, {_completed, frame}} ->
        stats |> bump(:aus) |> bump(:frames) |> push(stream_ref, frame)

      {:error, reason} ->
        bump_error(stats, reason)
    end
  end

  # Two accumulators, because the difference between them is the answer: a
  # non-sampled call is decode alone, a sampled one is decode plus the scale
  # and the motion measurement (`to_rgb`). Whether the expensive half is the
  # decoder or the scaler decides whether a GPU resize path is worth building.
  defp decode_timing(stats, true, us),
    do: %{stats | sampled_us: stats.sampled_us + us, sampled_n: stats.sampled_n + 1}

  defp decode_timing(stats, false, us),
    do: %{
      stats
      | decode_only_us: stats.decode_only_us + us,
        decode_only_n: stats.decode_only_n + 1
    }

  # Mirrors `Cairn.Pipeline.Inference`'s split of a decoded frame into
  # `push_frame/4`'s payload and `t:CairnOrt.frame_meta/0`.
  defp push(stats, stream_ref, frame) do
    meta = %{
      width: frame.width,
      height: frame.height,
      orig_width: frame.orig_width,
      orig_height: frame.orig_height,
      pts: frame.pts,
      observed_at_ms: frame.observed_at_ms,
      motion: frame.motion
    }

    started = System.monotonic_time(:microsecond)
    result = CairnOrt.push_frame(stream_ref, frame.payload, meta, @time_base)
    latency_us = System.monotonic_time(:microsecond) - started

    stats = stats |> bump(:passes) |> latency(latency_us)

    case result do
      {:ok, {observations, _ended_tracks}} -> bump(stats, :observations, length(observations))
      {:error, reason} -> bump_error(stats, reason)
    end
  end

  # -- stats ------------------------------------------------------------------

  defp init_stats(t0, sample_every \\ 1) do
    %{
      sample_every: sample_every,
      sampled_us: 0,
      sampled_n: 0,
      decode_only_us: 0,
      decode_only_n: 0,
      aus: 0,
      frames: 0,
      passes: 0,
      observations: 0,
      errors: %{},
      lat_hist: %{},
      lat_count: 0,
      lat_max: 0,
      t0: t0,
      last_progress: t0
    }
  end

  defp bump(stats, key, n \\ 1), do: Map.update!(stats, key, &(&1 + n))

  # A histogram, not a list: a multi-hour soak makes millions of passes, and
  # an unbounded list re-sorted at every report would turn the harness into
  # the bottleneck it exists to find. 100 us buckets bound the percentile
  # error at 0.1 ms — an order of magnitude under anything reported here —
  # and memory at the spread of observed latencies, not their count.
  @lat_bucket_us 100

  defp latency(stats, us) do
    bucket = div(us, @lat_bucket_us)

    %{
      stats
      | lat_hist: Map.update(stats.lat_hist, bucket, 1, &(&1 + 1)),
        lat_count: stats.lat_count + 1,
        lat_max: max(stats.lat_max, us)
    }
  end

  defp bump_error(stats, {reason, _message}) when is_atom(reason), do: bump_error(stats, reason)

  defp bump_error(stats, reason) when is_atom(reason) do
    %{stats | errors: Map.update(stats.errors, reason, 1, &(&1 + 1))}
  end

  defp bump_error(stats, other), do: bump_error(stats, {:unrecognized, other})

  defp maybe_progress(stats, label, now) do
    if now - stats.last_progress >= @progress_interval_ms do
      report(label, stats)
      %{stats | last_progress: now}
    else
      stats
    end
  end

  defp report(label, stats) do
    {p50, p95, max} = percentiles(stats)
    elapsed_s = div(now_ms() - stats.t0, 1000)

    IO.puts(
      "board-soak: #{label} t=#{elapsed_s}s aus=#{stats.aus} frames=#{stats.frames} " <>
        "passes=#{stats.passes} observations=#{stats.observations} " <>
        "latency_us(p50=#{p50} p95=#{p95} max=#{max}) " <>
        "decode_us(sampled=#{mean_us(stats.sampled_us, stats.sampled_n)}/#{stats.sampled_n} " <>
        "plain=#{mean_us(stats.decode_only_us, stats.decode_only_n)}/#{stats.decode_only_n}) " <>
        "errors=#{inspect(stats.errors)}"
    )
  end

  # Mean rather than a percentile: these two feed a subtraction (conversion =
  # sampled - plain), and subtracting two percentiles measured over different
  # call populations would not mean anything.
  defp mean_us(_total, 0), do: 0
  defp mean_us(total, n), do: div(total, n)

  defp percentiles(%{lat_count: 0}), do: {0, 0, 0}

  defp percentiles(stats) do
    buckets = Enum.sort(stats.lat_hist)
    {at(buckets, stats.lat_count, 0.50), at(buckets, stats.lat_count, 0.95), stats.lat_max}
  end

  # The bucket's midpoint stands in for every latency inside it; `max` is
  # exact because it is tracked beside the histogram.
  defp at(buckets, count, fraction) do
    wanted = max(1, min(count, trunc(fraction * count) + 1))

    {bucket, _seen} =
      Enum.reduce_while(buckets, {0, 0}, fn {bucket, n}, {_last, seen} ->
        if seen + n >= wanted, do: {:halt, {bucket, seen + n}}, else: {:cont, {bucket, seen + n}}
      end)

    bucket * @lat_bucket_us + div(@lat_bucket_us, 2)
  end

  defp summarize(results) do
    total =
      Enum.reduce(results, init_stats(now_ms()), fn stats, acc ->
        %{
          acc
          | aus: acc.aus + stats.aus,
            frames: acc.frames + stats.frames,
            passes: acc.passes + stats.passes,
            observations: acc.observations + stats.observations,
            errors: Map.merge(acc.errors, stats.errors, fn _reason, a, b -> a + b end),
            lat_hist: Map.merge(acc.lat_hist, stats.lat_hist, fn _bucket, a, b -> a + b end),
            lat_count: acc.lat_count + stats.lat_count,
            lat_max: max(acc.lat_max, stats.lat_max)
        }
      end)

    IO.puts("board-soak: summary — #{length(results)} stream(s)")
    report("total", total)
  end

  # -- clip ---------------------------------------------------------------

  @doc """
  Parses a packed access-unit file: repeated
  `<<pts::signed-64, size::unsigned-32, au::binary-size(size)>>`.
  """
  @spec read_clip(String.t() | nil) :: {:ok, [{binary(), integer()}]} | {:error, term()}
  def read_clip(nil), do: {:error, :no_clip_configured}

  def read_clip(path) do
    case File.read(path) do
      {:ok, bin} -> parse_clip(bin, [])
      {:error, reason} -> {:error, {:clip_unreadable, reason}}
    end
  end

  defp parse_clip(<<>>, acc), do: finish_clip(acc)

  defp parse_clip(
         <<pts::signed-64, size::unsigned-32, au::binary-size(size), rest::binary>>,
         acc
       ),
       do: parse_clip(rest, [{au, pts} | acc])

  defp parse_clip(_leftover, _acc), do: {:error, :clip_malformed}

  defp finish_clip([]), do: {:error, :clip_empty}
  defp finish_clip(acc), do: {:ok, Enum.reverse(acc)}

  # -- options --------------------------------------------------------------

  defp options(opts) do
    given = Map.new(opts)

    %{
      model: string_opt(given, :model, "BOARD_SOAK_MODEL"),
      labels: string_opt(given, :labels, "BOARD_SOAK_LABELS"),
      backend: string_opt(given, :backend, "BOARD_SOAK_BACKEND"),
      qnn_library: string_opt(given, :qnn_library, "BOARD_SOAK_QNN_LIBRARY"),
      clip: Map.get(given, :clip, System.get_env("BOARD_SOAK_CLIP", @defaults.clip)),
      seconds: integer_opt(given, :seconds, "BOARD_SOAK_SECONDS"),
      streams: integer_opt(given, :streams, "BOARD_SOAK_STREAMS"),
      sample_fps: integer_opt(given, :sample_fps, "BOARD_SOAK_SAMPLE_FPS"),
      decoder: string_opt(given, :decoder, "BOARD_SOAK_DECODER"),
      source_width: integer_opt(given, :source_width, "BOARD_SOAK_SOURCE_WIDTH"),
      source_height: integer_opt(given, :source_height, "BOARD_SOAK_SOURCE_HEIGHT"),
      sample_every: integer_opt(given, :sample_every, "BOARD_SOAK_SAMPLE_EVERY")
    }
  end

  defp string_opt(given, key, env) do
    case Map.fetch(given, key) do
      {:ok, value} -> value
      :error -> System.get_env(env, Map.fetch!(@defaults, key))
    end
  end

  defp integer_opt(given, key, env) do
    case Map.fetch(given, key) do
      {:ok, value} when is_integer(value) or is_nil(value) ->
        value

      :error ->
        case System.get_env(env) do
          nil -> Map.fetch!(@defaults, key)
          value -> String.to_integer(value)
        end
    end
  end

  defp announce(opts) do
    IO.puts(
      "board-soak: model=#{opts.model} backend=#{opts.backend} decoder=#{opts.decoder} " <>
        "source=#{opts.source_width}x#{opts.source_height} clip=#{inspect(opts.clip)} " <>
        "streams=#{opts.streams} seconds=#{opts.seconds}"
    )
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
