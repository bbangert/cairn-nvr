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

defmodule Cairn.CameraTracker do
  @moduledoc """
  Stand-in for the application's tracker, shaped exactly like the two
  `detections` heads `Cairn.Detect.Dispatch` calls — the harness compiles
  this file instead of `lib/cairn/camera_tracker.ex`, whose real module
  drags in the tracker pool, Ecto and PubSub. The sink is always given an
  explicit `tracker:`, so the 3-arity head (the camera's own tracker) is
  unreachable here and refuses loudly rather than counting nothing.
  """

  alias Cairn.Observation

  def detections(camera, _policy, %Observation{}) do
    raise "board-pipeline: dispatch for #{camera.id} lost its tracker override"
  end

  def detections(nil, camera, policy, observation), do: detections(camera, policy, observation)

  # The same cast the real tracker receives, so the collector measures the
  # production dispatch path and not a harness-only shortcut.
  def detections(server, camera, policy, %Observation{} = observation),
    do: GenServer.cast(server, {:detections, camera, policy, observation})
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

    {:ok,
     %{
       t0: t0,
       observations: 0,
       objects: 0,
       last_at_ms: nil,
       # gap ms -> count, as board-soak's latency histogram: a board run of
       # hours must not accumulate an unbounded list to re-sort per report.
       gaps: %{},
       gap_count: 0,
       decoder_opens: [],
       stats: %{}
     }}
  end

  @impl true
  def handle_cast({:detections, _camera, _policy, observation}, state) do
    now = System.monotonic_time(:millisecond)

    state =
      case state.last_at_ms do
        nil ->
          state

        last ->
          gap = now - last

          %{
            state
            | gaps: Map.update(state.gaps, gap, 1, &(&1 + 1)),
              gap_count: state.gap_count + 1
          }
      end

    {:noreply,
     %{
       state
       | observations: state.observations + 1,
         objects: state.objects + length(observation.objects),
         last_at_ms: now
     }}
  end

  @impl true
  def handle_info({:decoder_open, source, at_ms}, state) do
    {:noreply, %{state | decoder_opens: state.decoder_opens ++ [{source, at_ms - state.t0}]}}
  end

  def handle_info({:stats, child, stats}, state) do
    {:noreply, %{state | stats: Map.put(state.stats, child, stats)}}
  end

  def handle_info(:progress, state) do
    Process.send_after(self(), :progress, @progress_interval_ms)
    IO.puts("board-pipeline: " <> line(state))
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_call(:summary, _from, state) do
    {:reply,
     %{
       observations: state.observations,
       objects: state.objects,
       gap_p50_ms: gap_p50(state),
       decoder_opens: state.decoder_opens,
       stats: state.stats,
       line: line(state)
     }, state}
  end

  defp line(state) do
    elapsed_s = div(System.monotonic_time(:millisecond) - state.t0, 1000)

    "t=#{elapsed_s}s observations=#{state.observations} objects=#{state.objects} " <>
      "gap_p50_ms=#{gap_p50(state)}"
  end

  defp gap_p50(%{gap_count: 0}), do: nil

  defp gap_p50(state) do
    wanted = max(1, trunc(0.5 * state.gap_count) + 1)

    {gap, _seen} =
      state.gaps
      |> Enum.sort()
      |> Enum.reduce_while({0, 0}, fn {gap, n}, {_last, seen} ->
        if seen + n >= wanted, do: {:halt, {gap, seen + n}}, else: {:cont, {gap, seen + n}}
      end)

    gap
  end
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

  alias Cairn.BoardPipeline.AuSource
  alias Cairn.Pipeline.{Decoder, DetectSink, Inference, Picker}

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
      |> child(:detect, %DetectSink{
        camera: camera,
        # Carried unread through Dispatch into the collector's cast; the real
        # resolver (`Cairn.Config.policy/2`) lives in modules this harness
        # deliberately does not compile.
        policy: %{},
        epoch: epoch,
        tracker: collector
      })

    {[spec: spec], %{collector: collector}}
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
    send(state.collector, {:stats, child, stats})
    {[], state}
  end

  def handle_child_notification(_notification, _child, _ctx, state), do: {[], state}
end

defmodule Cairn.BoardPipeline do
  @moduledoc """
  Runs cairn's real membrane detect branch — parser, `Cairn.Pipeline.Picker`,
  `Cairn.Pipeline.Decoder`, `Cairn.Pipeline.Inference`,
  `Cairn.Pipeline.DetectSink` — against a real `Cairn.Native.Host` (with its
  `Cairn.Native.Health` monitor) in a standalone BEAM: plan task 5.2's other
  half. `Cairn.BoardSoak` asks whether the NIFs survive; this asks whether
  the *pipeline around them* behaves — the format-driven decoder open, the
  one-frame manual seams, the dispatch into a tracker.

  Compiled with `elixirc`, not `mix`: no release and no cairn application,
  only the module subset `tools/board-pipeline/run-local.sh` lists plus the
  membrane closure. The seams that keep the rest of the app out:

    * `Host.start_link(config: ...)` — a non-nil `:config` opt means
      `Cairn.Config.Server` is never consulted;
    * `canary: [enabled: false]` — no `cairn-detect` binary is spawned;
    * a `stream_epoch` in the inference params — `Cairn.StreamEpochs` is
      short-circuited (its ETS-missing paths answer `:unknown` harmlessly);
    * DetectSink's `tracker:` — dispatch casts to the collector instead of a
      camera tracker pool.

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
      with :ok <- start_apps(),
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

    camera = %Camera{id: @camera_id, rtsp_url: "rtsp://board-pipeline.invalid/clip"}
    epoch = Cairn.ULID.generate()

    {:ok, _supervisor, pipeline} =
      Membrane.Pipeline.start_link(Pipe,
        camera: camera,
        epoch: epoch,
        collector: collector,
        clip: clip,
        seconds: opts.seconds
      )

    # One extra second so the source's own deadline fires and end_of_stream
    # drains through the sink before teardown starts.
    Process.sleep(opts.seconds * 1000 + 1000)
    send(pipeline, :stats)
    Process.sleep(300)
    :ok = Membrane.Pipeline.terminate(pipeline, timeout: 10_000)

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
        "#{div(1000, opts.sample_fps)}ms, measured p50 #{inspect(summary.gap_p50_ms)}ms"
    )

    Enum.each(summary.stats, fn {child, stats} ->
      IO.puts("board-pipeline: stats #{child}=#{inspect(stats)}")
    end)
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
        "sample_fps=#{opts.sample_fps} clip=#{inspect(opts.clip)} seconds=#{opts.seconds}"
    )
  end
end
