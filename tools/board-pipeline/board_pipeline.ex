defmodule Cairn.Config do
  @moduledoc """
  Struct-only stand-in: `Cairn.Native.Host.reconfigure/2` pattern-matches
  `%Cairn.Config{}`, and an undefined struct in a pattern is a compile
  *error* where an undefined remote call is only a warning. Reconfigure is
  the config-reload path, which this harness never takes — no field of the
  real struct is ever read here, so none are declared.
  """

  defstruct []
end

defmodule Cairn.BoardPipeline.DetectionSink do
  @moduledoc """
  The harness's own terminus, and the one place it stops being the production
  spec verbatim.

  Production ends the branch in three host-side elements —
  `Cairn.Pipeline.ObservationStamper`, the generic `Membrane.MOTTracker` and
  `Cairn.Pipeline.TrackSink` — none of which touch a NIF, and whose closure
  (the tracker core, its stages, the runtime control overlay) is most of the
  application. This harness asks what the pipeline *around the NIFs* does, so
  it ends where the NIF's output does: at `Inference`'s own pad, counting the
  frames it emits.
  """

  use Membrane.Sink

  alias Cairn.Pipeline.Inference.Detections

  def_input_pad(:input, accepted_format: %Detections{}, flow_control: :auto)

  def_options(camera_id: [spec: String.t()], collector: [spec: pid()])

  @impl true
  def handle_init(_ctx, opts), do: {[], %{camera_id: opts.camera_id, collector: opts.collector}}

  @impl true
  def handle_buffer(:input, %{metadata: %{observations: observations}}, _ctx, state) do
    GenServer.cast(state.collector, {:detections, state.camera_id, observations})
    {[], state}
  end

  def handle_buffer(:input, _buffer, _ctx, state), do: {[], state}
end

defmodule Cairn.BoardPipeline.AuSource do
  @moduledoc """
  Push source for the packed clip, paced at the clip's own rate: unlike
  `Cairn.BoardSoak`, which feeds back to back to measure the NIFs, this
  harness measures the *pipeline*, and the sample gate, the picker's slot and
  inference demand only mean anything against real inter-frame time.

  Output is `Cairn.Pipeline.RtspSource`'s exact pad: a packetized
  `Membrane.RemoteStream` of whole Annex-B access units with nanosecond pts,
  for `Membrane.H264.Parser` to turn into `%Membrane.H264{alignment: :au}`
  with the SPS geometry in the stream format — the format-driven decoder
  open this harness exists to exercise.
  """

  use Membrane.Source

  def_options(
    clip: [spec: [{binary(), integer()}], description: "Access units with 90 kHz pts"],
    seconds: [spec: pos_integer(), description: "How long to loop before end_of_stream"]
  )

  def_output_pad(:output,
    accepted_format: %Membrane.RemoteStream{type: :packetized, content_format: Membrane.H264},
    flow_control: :push
  )

  @pts_hz 90_000

  @impl true
  def handle_init(_ctx, opts) do
    interval_ns = interval_ns(opts.clip)

    {[],
     %{
       clip: opts.clip,
       remaining: opts.clip,
       seconds: opts.seconds,
       interval_ns: interval_ns,
       # Each pass through the clip shifts pts by its span plus one frame, so
       # timestamps stay strictly increasing across the loop seam — a rewind
       # would re-anchor the observation clock and end every track.
       stride_ns: span_ns(opts.clip) + interval_ns,
       offset_ns: 0,
       deadline_ms: nil
     }}
  end

  @impl true
  def handle_playing(_ctx, state) do
    {[
       stream_format:
         {:output, %Membrane.RemoteStream{type: :packetized, content_format: Membrane.H264}},
       start_timer: {:pace, Membrane.Time.nanoseconds(state.interval_ns)}
     ], %{state | deadline_ms: System.monotonic_time(:millisecond) + state.seconds * 1000}}
  end

  @impl true
  def handle_tick(:pace, _ctx, state) do
    if System.monotonic_time(:millisecond) >= state.deadline_ms do
      {[stop_timer: :pace, end_of_stream: :output], state}
    else
      emit(state)
    end
  end

  defp emit(%{remaining: [{au, pts90} | rest]} = state) do
    buffer = %Membrane.Buffer{
      payload: au,
      pts: div(pts90 * 1_000_000_000, @pts_hz) + state.offset_ns
    }

    state =
      case rest do
        [] -> %{state | remaining: state.clip, offset_ns: state.offset_ns + state.stride_ns}
        rest -> %{state | remaining: rest}
      end

    {[buffer: {:output, buffer}], state}
  end

  # The median of positive deltas, not the first: the clip is in decode
  # order, where B-frames make individual pts steps negative or double-sized.
  defp interval_ns(clip) do
    deltas =
      clip
      |> Enum.map(fn {_au, pts} -> pts end)
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] -> b - a end)
      |> Enum.filter(&(&1 > 0))
      |> Enum.sort()

    interval_90k =
      case deltas do
        [] -> div(@pts_hz, 30)
        deltas -> Enum.at(deltas, div(length(deltas), 2))
      end

    div(interval_90k * 1_000_000_000, @pts_hz)
  end

  defp span_ns(clip) do
    {min, max} = clip |> Enum.map(fn {_au, pts} -> pts end) |> Enum.min_max()
    div((max - min) * 1_000_000_000, @pts_hz)
  end
end

defmodule Cairn.BoardPipeline.Collector do
  @moduledoc """
  Receives what the pipeline produces and says what it saw: the tracker-cast
  observations from `Cairn.Detect.Dispatch`, the decoder-open evidence from
  the `:sys` hook on the host, and each element's `:stats` notification. IO
  is `IO.puts` with a `board-pipeline:` prefix, matching `Cairn.BoardSoak`'s
  ssh-log discipline.
  """

  use GenServer

  @progress_interval_ms 30_000

  def start_link do
    GenServer.start_link(__MODULE__, System.monotonic_time(:millisecond))
  end

  @impl true
  def init(t0) do
    Process.send_after(self(), :progress, @progress_interval_ms)
    counters = cpu_counters()

    {:ok,
     %{
       t0: t0,
       # camera id -> its own counters, so an N-stream capacity run can say
       # which stream fell behind rather than averaging the shortfall away.
       cams: %{},
       decoder_opens: [],
       stats: %{},
       # cpu_first anchors the whole-run average; cpu_last is the rolling
       # anchor for the per-tick progress figure.
       cpu_first: counters,
       cpu_last: counters,
       cpu_tick: nil
     }}
  end

  # Gaps land in 10 ms buckets: the histogram's key count is then bounded by
  # the gap range, not the run length — exact-ms keys under scheduler jitter
  # would grow ~1:1 with gap_count on an hour run. 10 ms is 5% of the 200 ms
  # expected gap, well under what the p50 is read for.
  @gap_bucket_ms 10

  defp new_cam do
    %{
      observations: 0,
      objects: 0,
      last_at_ms: nil,
      # bucketed gap ms -> count, as board-soak's latency histogram: a board
      # run of hours must not accumulate an unbounded list to re-sort.
      gaps: %{},
      gap_count: 0
    }
  end

  @impl true
  def handle_cast({:detections, camera_id, observations}, state) do
    now = System.monotonic_time(:millisecond)
    cam = Map.get_lazy(state.cams, camera_id, &new_cam/0)

    cam =
      case cam.last_at_ms do
        nil ->
          cam

        last ->
          bucket = div(now - last, @gap_bucket_ms) * @gap_bucket_ms
          %{cam | gaps: Map.update(cam.gaps, bucket, 1, &(&1 + 1)), gap_count: cam.gap_count + 1}
      end

    cam = %{
      cam
      | observations: cam.observations + length(observations),
        objects: cam.objects + Enum.sum(Enum.map(observations, &length(&1.objects))),
        last_at_ms: now
    }

    {:noreply, %{state | cams: Map.put(state.cams, camera_id, cam)}}
  end

  @impl true
  def handle_info({:decoder_open, source, at_ms}, state) do
    {:noreply, %{state | decoder_opens: state.decoder_opens ++ [{source, at_ms - state.t0}]}}
  end

  def handle_info({:stats, camera_id, child, stats}, state) do
    {:noreply, %{state | stats: Map.put(state.stats, {camera_id, child}, stats)}}
  end

  def handle_info(:progress, state) do
    Process.send_after(self(), :progress, @progress_interval_ms)
    {sample, state} = cpu_sample(state)
    state = %{state | cpu_tick: sample}
    IO.puts("board-pipeline: " <> line(state, sample))
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_call(:summary, _from, state) do
    run_avg = cpu_run_avg(state)

    {:reply,
     %{
       cams:
         Map.new(state.cams, fn {id, cam} ->
           {id,
            %{
              observations: cam.observations,
              objects: cam.objects,
              gap_p50_ms: gap_p50(cam)
            }}
         end),
       cpu_pct: run_avg,
       decoder_opens: state.decoder_opens,
       stats: state.stats,
       line: line(state, run_avg)
     }, state}
  end

  # Progress ticks pass their own interval's figure; the summary passes the
  # whole-run average — never a mean of the two kinds.
  defp line(state, cpu_pct) do
    elapsed_s = div(System.monotonic_time(:millisecond) - state.t0, 1000)
    {observations, objects} = totals(state)

    "t=#{elapsed_s}s streams=#{map_size(state.cams)} observations=#{observations} " <>
      "objects=#{objects} cpu_pct=#{inspect(cpu_pct)}"
  end

  defp totals(state) do
    Enum.reduce(state.cams, {0, 0}, fn {_id, cam}, {obs, objs} ->
      {obs + cam.observations, objs + cam.objects}
    end)
  end

  defp gap_p50(%{gap_count: 0}), do: nil

  defp gap_p50(cam) do
    wanted = max(1, trunc(0.5 * cam.gap_count) + 1)

    {gap, _seen} =
      cam.gaps
      |> Enum.sort()
      |> Enum.reduce_while({0, 0}, fn {gap, n}, {_last, seen} ->
        if seen + n >= wanted, do: {:halt, {gap, seen + n}}, else: {:cont, {gap, seen + n}}
      end)

    gap
  end

  # -- cpu --------------------------------------------------------------------

  # Whole-system busy time from /proc/stat, sampled per progress tick: the
  # capacity question is "what does N streams cost the box", and the busybox
  # rootfs has no top/mpstat to ask instead.
  defp cpu_counters do
    with {:ok, stat} <- File.read("/proc/stat"),
         "cpu " <> rest <- stat |> String.split("\n", parts: 2) |> hd() do
      fields =
        rest
        |> String.split(" ", trim: true)
        |> Enum.map(&String.to_integer/1)

      case fields do
        [_user, _nice, _system, idle | tail] ->
          iowait = Enum.at(tail, 0, 0)
          total = Enum.sum(fields)
          {total - idle - iowait, total}

        _short ->
          nil
      end
    else
      _unreadable -> nil
    end
  end

  defp cpu_sample(%{cpu_last: nil} = state), do: {nil, %{state | cpu_last: cpu_counters()}}

  defp cpu_sample(%{cpu_last: {busy0, total0}} = state) do
    case cpu_counters() do
      {busy1, total1} = counters when total1 > total0 ->
        pct = Float.round(100.0 * (busy1 - busy0) / (total1 - total0), 1)
        {pct, %{state | cpu_last: counters}}

      _unreadable ->
        {nil, state}
    end
  end

  # Whole-run average from cumulative counters — time-weighted by
  # construction. A mean of the per-tick samples would weight the summary's
  # short final window the same as a full 30 s interval (Copilot, PR #99).
  defp cpu_run_avg(%{cpu_first: {busy0, total0}}) do
    case cpu_counters() do
      {busy1, total1} when total1 > total0 ->
        Float.round(100.0 * (busy1 - busy0) / (total1 - total0), 1)

      _unreadable ->
        nil
    end
  end

  defp cpu_run_avg(_no_first_counters), do: nil
end

defmodule Cairn.BoardPipeline.Pipe do
  @moduledoc """
  The detect branch of `Cairn.Pipeline.Camera`, minus the tee and the other
  branches: source and parser stand in for an ingest session, everything from
  the picker on is the production spec verbatim — the manual-pad `via_in`
  options between picker/decoder/inference are the load-bearing one-frame
  seams and are copied, not re-derived.
  """

  use Membrane.Pipeline

  alias Cairn.BoardPipeline.{AuSource, DetectionSink}
  alias Cairn.Pipeline.{Decoder, Inference, Picker}

  @impl true
  def handle_init(_ctx, opts) do
    camera = Keyword.fetch!(opts, :camera)
    epoch = Keyword.fetch!(opts, :epoch)
    collector = Keyword.fetch!(opts, :collector)

    spec =
      child(:source, %AuSource{
        clip: Keyword.fetch!(opts, :clip),
        seconds: Keyword.fetch!(opts, :seconds)
      })
      # `Cairn.Pipeline.Camera`'s rtsp ingest pairing: the parser re-emits
      # AU-aligned Annex-B with the SPS geometry in the stream format, which
      # is what drives the decoder's format-driven open.
      |> child(:ingest_parser, %Membrane.H264.Parser{
        output_alignment: :au,
        output_stream_structure: :annexb
      })
      |> child(:picker, Picker)
      # One AU between the two, so the picker learns that the decoder is free
      # the moment it is, and no more than one is ever in flight.
      |> via_in(:input, target_queue_size: 1, min_demand_factor: 0.5)
      |> child(:decoder, %Decoder{camera_id: camera.id, stream_params: %{}})
      # …and one sampled frame between decoder and inference, for the same
      # reason: inference demands only after `push_frame/5` returns.
      |> via_in(:input, target_queue_size: 1, min_demand_factor: 0.5)
      |> child(:infer, %Inference{
        session: {Cairn.Native.Host, Cairn.Native.Host},
        stream_id: camera.id,
        stream_params: %{stream_epoch: epoch}
      })
      |> child(:detect, %DetectionSink{camera_id: camera.id, collector: collector})

    {[spec: spec], %{collector: collector, camera_id: camera.id}}
  end

  @impl true
  def handle_info(:stats, _ctx, state) do
    {[
       notify_child: {:picker, :stats},
       notify_child: {:decoder, :stats},
       notify_child: {:infer, :stats},
       notify_child: {:detect, :stats}
     ], state}
  end

  @impl true
  def handle_child_notification({:stats, stats}, child, _ctx, state) do
    send(state.collector, {:stats, state.camera_id, child, stats})
    {[], state}
  end

  def handle_child_notification(_notification, _child, _ctx, state), do: {[], state}
end

defmodule Cairn.BoardPipeline do
  @moduledoc """
  Runs cairn's real membrane detect branch — parser, `Cairn.Pipeline.Picker`,
  `Cairn.Pipeline.Decoder`, `Cairn.Pipeline.Inference` — against a real
  `Cairn.Native.Host` (with its `Cairn.Native.Health` monitor) in a standalone
  BEAM: plan task 5.2's other half. `Cairn.BoardSoak` asks whether the NIFs
  survive; this asks whether the *pipeline around them* behaves — the
  format-driven decoder open, the one-frame manual seams, the pacing of the
  model call.

  Compiled with `elixirc`, not `mix`: no release and no cairn application,
  only the module subset `tools/board-pipeline/run-local.sh` lists plus the
  membrane closure. The seams that keep the rest of the app out:

    * `Host.start_link(config: ...)` — a non-nil `:config` opt means
      `Cairn.Config.Server` is never consulted;
    * `canary: [enabled: false]` — no `cairn-detect` binary is spawned;
    * a `stream_epoch` in the inference params — `Cairn.StreamEpochs` is
      short-circuited (its ETS-missing paths answer `:unknown` harmlessly);
    * `Cairn.BoardPipeline.DetectionSink` — the branch ends at the inference
      element's pad, so the host-side tracker closure stays out (see that
      module).

  The undefined-module warnings the standalone compile emits — `Cairn.Config`
  / `Cairn.Config.Server` (host.ex, config/camera.ex, canary.ex) and
  `Phoenix.PubSub` (stream_epochs.ex, host.ex) — are remote calls this path
  never takes.
  """

  alias Cairn.BoardPipeline.{Collector, Pipe}
  alias Cairn.Config.Camera
  alias Cairn.Native.Health
  alias Cairn.Native.Host

  @camera_id "board-pipeline"

  # Everything membrane_core's runtime closure needs is pure BEAM; the two
  # format apps and the parser ride on top.
  @apps [
    :telemetry,
    :membrane_core,
    :membrane_raw_video_format,
    :membrane_h264_format,
    :membrane_h26x_plugin
  ]

  @defaults %{
    model: "/data/cairn-bench/yolox_nano-qdq.onnx",
    labels: "/data/cairn-bench/coco.names",
    backend: "qnn",
    qnn_library: "/data/cairn-bench/libonnxruntime_providers_qnn.so",
    clip: nil,
    seconds: 300,
    decoder: "auto",
    sample_fps: 5,
    streams: 1,
    # `.so`-less NIF paths for `Application.put_env`; absent falls back to
    # `:code.priv_dir(:cairn)`, which only resolves when cairn's ebin is on
    # the code path.
    native_lib: nil,
    ort_lib: nil
  }

  @doc """
  Run the pipeline harness. `opts` is a map or keyword list; any key left out
  reads `BOARD_PIPELINE_<KEY>` from the environment, then this module's
  default.
  """
  @spec run(map() | keyword()) :: :ok | {:error, term()}
  def run(opts \\ []) do
    opts = options(opts)
    announce(opts)
    # Before anything loads the NIF modules: `@on_load` fires once, at module
    # load, and reads this env.
    configure_nif_paths(opts)

    result =
      with :ok <- validate_positive(opts, :streams),
           :ok <- validate_positive(opts, :seconds),
           :ok <- start_apps(),
           :ok <- check_available(),
           {:ok, clip} <- read_clip(opts.clip) do
        with_stack(opts, clip)
      end

    # As `Cairn.BoardSoak`: make the deferred native drops queue and run now,
    # so the halt that follows never races the cairn-teardown thread.
    :erlang.garbage_collect()

    drains = %{
      native: Cairn.Native.available?() and Cairn.Native.drain_teardown(10_000),
      ort: CairnOrt.available?() and CairnOrt.drain_teardown(10_000)
    }

    IO.puts("board-pipeline: drains native=#{drains.native} ort=#{drains.ort}")
    result
  end

  defp with_stack(opts, clip) do
    {:ok, _task_sup} = Task.Supervisor.start_link(name: Cairn.TaskSupervisor)
    {:ok, host} = Host.start_link(config: host_config(opts), canary: [enabled: false])
    {:ok, health} = Health.start_link(host: Host)

    result =
      case await_engine() do
        :ok -> run_pipeline(opts, clip)
        error -> error
      end

    GenServer.stop(health)
    GenServer.stop(host)
    # The host's stream closes run in tasks that outlive it; give them the
    # moment they need before the drains below account for their drops.
    # Grace for the ResourceGuard's async cleanups and the host's close tasks;
    # the bounded drains below are the actual backstop if 500 ms was not it.
    Process.sleep(500)
    result
  end

  defp host_config(opts) do
    %{
      model: opts.model,
      labels: opts.labels,
      backend: opts.backend,
      decoder: opts.decoder,
      sample_fps: opts.sample_fps,
      qnn: %{library: opts.qnn_library}
    }
  end

  # The status call queues behind the model load `init/1` runs in its
  # continue, so one long-deadline call is the readiness barrier — a QNN HTP
  # graph compile is multi-second.
  defp await_engine do
    case Host.status(Host, 300_000) do
      %{engine: :ready} = status ->
        IO.puts("board-pipeline: engine ready — model #{status.model} backend #{status.backend}")

        :ok

      %{engine: refused} ->
        IO.puts("board-pipeline: refusing to run — engine is #{inspect(refused)}")
        {:error, {:engine, refused}}
    end
  end

  defp run_pipeline(opts, clip) do
    {:ok, collector} = Collector.start_link()
    install_decoder_probe(collector)

    # One pipeline per stream against the one shared Host — the capacity
    # question is how many detect branches this box carries at sample_fps.
    pipelines =
      for n <- 1..opts.streams do
        camera = %Camera{
          id: "#{@camera_id}-#{n}",
          rtsp_url: "rtsp://board-pipeline.invalid/clip-#{n}"
        }

        {:ok, _supervisor, pipeline} =
          Membrane.Pipeline.start_link(Pipe,
            camera: camera,
            epoch: Cairn.ULID.generate(),
            collector: collector,
            clip: clip,
            seconds: opts.seconds
          )

        pipeline
      end

    # One extra second so the source's own deadline fires and end_of_stream
    # drains through the sink before teardown starts.
    Process.sleep(opts.seconds * 1000 + 1000)
    Enum.each(pipelines, &send(&1, :stats))
    Process.sleep(300)
    Enum.each(pipelines, &(:ok = Membrane.Pipeline.terminate(&1, timeout: 10_000)))

    summarize(GenServer.call(collector, :summary), opts)
    GenServer.stop(collector)
    :ok
  end

  # A `:sys` debug hook on the host: `Cairn.Pipeline.Decoder` opens through a
  # hard-wired `Host.open_decoder` call, so the `source` argument crossing the
  # host's mailbox is the only externally observable proof that the parser's
  # geometry-bearing stream format arrived before the open — the decoder has
  # no other way to learn a `{w, h}`.
  defp install_decoder_probe(collector) do
    :sys.install(
      Process.whereis(Host),
      {fn acc, event, _proc_state ->
         case decoder_open(event) do
           {:ok, source} ->
             send(collector, {:decoder_open, source, System.monotonic_time(:millisecond)})

           :not_one ->
             :ok
         end

         acc
       end, :ok}
    )
  end

  defp decoder_open({:in, message}), do: decoder_open_message(message)
  defp decoder_open({:in, message, _from}), do: decoder_open_message(message)
  defp decoder_open(_event), do: :not_one

  defp decoder_open_message({:"$gen_call", _from, {:open_decoder, _camera, _params, source}}),
    do: {:ok, source}

  defp decoder_open_message(_message), do: :not_one

  defp summarize(summary, opts) do
    IO.puts("board-pipeline: summary — " <> summary.line)

    opens =
      Enum.map_join(summary.decoder_opens, ", ", fn {source, at_ms} ->
        "#{inspect(source)} at +#{at_ms}ms"
      end)

    IO.puts(
      "board-pipeline: decoder opens (source geometry proves the parser's format led): " <>
        if(opens == "", do: "NONE — the decoder never opened", else: opens)
    )

    IO.puts(
      "board-pipeline: expected observation gap at sample_fps=#{opts.sample_fps} is " <>
        "#{div(1000, opts.sample_fps)}ms; cpu_pct=#{inspect(summary.cpu_pct)}"
    )

    summary.cams
    |> Enum.sort()
    |> Enum.each(fn {id, cam} ->
      per_s = Float.round(cam.observations / opts.seconds, 2)

      IO.puts(
        "board-pipeline: cam #{id} observations=#{cam.observations} (#{per_s}/s) " <>
          "objects=#{cam.objects} gap_p50_ms=#{inspect(cam.gap_p50_ms)}"
      )
    end)

    summary.stats
    |> Enum.sort()
    |> Enum.each(fn {{camera_id, child}, stats} ->
      IO.puts("board-pipeline: stats #{camera_id}/#{child}=#{inspect(stats)}")
    end)

    # The 300 ms window between :stats and terminate was sized for one
    # pipeline; with N of them a straggler's report can miss it. Absence
    # must be a line in the summary, not a silently shorter list.
    expected =
      for n <- 1..opts.streams,
          child <- [:picker, :decoder, :infer, :detect],
          do: {"#{@camera_id}-#{n}", child}

    case expected -- Map.keys(summary.stats) do
      [] ->
        :ok

      missing ->
        IO.puts(
          "board-pipeline: stats MISSING for " <>
            Enum.map_join(missing, ", ", fn {cam, child} -> "#{cam}/#{child}" end)
        )
    end
  end

  defp start_apps do
    Enum.reduce_while(@apps, :ok, fn app, :ok ->
      case Application.ensure_all_started(app) do
        {:ok, _started} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:app, app, reason}}}
      end
    end)
  end

  defp configure_nif_paths(opts) do
    put_lib(Cairn.Native, opts.native_lib)
    put_lib(CairnOrt, opts.ort_lib)
  end

  defp put_lib(_module, nil), do: :ok

  defp put_lib(module, path) do
    # `:erlang.load_nif/2` wants the path without the platform suffix; taking
    # the `.so` spelling too keeps the env var copy-pasteable from `ls`.
    Application.put_env(:cairn, module, path: String.trim_trailing(path, ".so"))
  end

  # `streams: 0` would make `1..opts.streams` a *descending* range and run
  # two streams — the exact off-by-configuration board-soak documents.
  # `seconds: 0` survives to the summary's per-second division and raises
  # there, after the run — refuse both up front.
  defp validate_positive(opts, key) do
    case Map.fetch!(opts, key) do
      value when is_integer(value) and value >= 1 ->
        :ok

      value ->
        IO.puts("board-pipeline: refusing to run — #{key} must be >= 1, got #{inspect(value)}")
        {:error, {key, value}}
    end
  end

  # A missing library must not read as a clean run.
  defp check_available do
    cond do
      not Cairn.Native.available?() ->
        IO.puts(
          "board-pipeline: cairn-native did not load: #{inspect(Cairn.Native.load_error())}"
        )

        {:error, :native_unavailable}

      not CairnOrt.available?() ->
        IO.puts("board-pipeline: cairn-ort did not load: #{inspect(CairnOrt.load_error())}")
        {:error, :ort_unavailable}

      true ->
        :ok
    end
  end

  # -- clip -------------------------------------------------------------------

  # `Cairn.BoardSoak`'s packed format: repeated
  # `<<pts::signed-64, size::unsigned-32, au::binary-size(size)>>`, pts at 90 kHz.
  defp read_clip(nil), do: {:error, :no_clip_configured}

  defp read_clip(path) do
    case File.read(path) do
      {:ok, bin} -> parse_clip(bin, [])
      {:error, reason} -> {:error, {:clip_unreadable, reason}}
    end
  end

  defp parse_clip(<<>>, []), do: {:error, :clip_empty}
  defp parse_clip(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp parse_clip(
         <<pts::signed-64, size::unsigned-32, au::binary-size(size), rest::binary>>,
         acc
       ),
       do: parse_clip(rest, [{au, pts} | acc])

  defp parse_clip(_leftover, _acc), do: {:error, :clip_malformed}

  # -- options ------------------------------------------------------------------

  defp options(opts) do
    given = Map.new(opts)

    %{
      model: string_opt(given, :model, "BOARD_PIPELINE_MODEL"),
      labels: string_opt(given, :labels, "BOARD_PIPELINE_LABELS"),
      backend: string_opt(given, :backend, "BOARD_PIPELINE_BACKEND"),
      # Blank means "no library" rather than the board default, so a wrapper
      # script can export the var unconditionally.
      qnn_library: blank_to_nil(string_opt(given, :qnn_library, "BOARD_PIPELINE_QNN_LIBRARY")),
      clip: Map.get(given, :clip, System.get_env("BOARD_PIPELINE_CLIP", @defaults.clip)),
      seconds: integer_opt(given, :seconds, "BOARD_PIPELINE_SECONDS"),
      decoder: string_opt(given, :decoder, "BOARD_PIPELINE_DECODER"),
      sample_fps: integer_opt(given, :sample_fps, "BOARD_PIPELINE_SAMPLE_FPS"),
      streams: integer_opt(given, :streams, "BOARD_PIPELINE_STREAMS"),
      native_lib:
        blank_to_nil(Map.get(given, :native_lib, System.get_env("BOARD_PIPELINE_NATIVE_LIB"))),
      ort_lib: blank_to_nil(Map.get(given, :ort_lib, System.get_env("BOARD_PIPELINE_ORT_LIB")))
    }
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp string_opt(given, key, env) do
    case Map.fetch(given, key) do
      {:ok, value} -> value
      :error -> System.get_env(env, Map.fetch!(@defaults, key))
    end
  end

  defp integer_opt(given, key, env) do
    case Map.fetch(given, key) do
      {:ok, value} when is_integer(value) ->
        value

      :error ->
        case System.get_env(env) do
          nil -> Map.fetch!(@defaults, key)
          value -> parse_integer(env, value, Map.fetch!(@defaults, key))
        end
    end
  end

  defp parse_integer(env, value, default) do
    case Integer.parse(value) do
      {n, ""} ->
        n

      _not_an_integer ->
        IO.puts(
          "board-pipeline: ignoring #{env}=#{inspect(value)} — not an integer; " <>
            "using #{inspect(default)}"
        )

        default
    end
  end

  defp announce(opts) do
    IO.puts(
      "board-pipeline: model=#{opts.model} backend=#{opts.backend} decoder=#{opts.decoder} " <>
        "sample_fps=#{opts.sample_fps} streams=#{opts.streams} clip=#{inspect(opts.clip)} " <>
        "seconds=#{opts.seconds}"
    )
  end
end
