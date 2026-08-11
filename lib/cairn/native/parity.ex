defmodule Cairn.Native.Parity do
  @moduledoc """
  The same clip through both detection producers, frame by frame: `cairn-detect`
  over RTP on 127.0.0.1, fed by `plugins/cairn-detect/verify/feed.py` and decoded
  by `Cairn.PluginProtocol.decode_line/2`, against the split NIF boundary —
  `Cairn.Native.decode_au/4` through `Cairn.Pipeline.SampleGate` into
  `CairnOrt.push_frame/4`, the very sequence `Cairn.Pipeline.Decoder` and
  `Cairn.Pipeline.Inference` run — over the clip's own access units. Both ends
  are `Cairn.Observation` structs.

  ## Why the comparison is exact

  Nothing on either path re-derives a number: `det_from` rounds the score to 3
  decimals and the bbox to 4 before the `Det` exists, and both producers carry that
  same `Det` — through `Jason` or through a term, each of which round-trips an f64
  exactly. So the expectation is bit equality, and `tolerance:` is there to absorb
  a decimal-parse edge. Widening it past 5.0e-4 would hide a whole quantum of score
  movement, which is the divergence this harness exists to find.

  ## What makes the two runs comparable at all

  Both paths thin frames on the *wall clock* (`--sample-fps`), so which frames reach
  the model is a property of the run and not of the clip — the `verify/` README
  measures two runs of one build sharing 3 lines of ~88. Two things fix that here:

    * `sample_fps: 30` against a ~20 fps clip. The gate's interval (33 ms) is then
      shorter than the frame period (50 ms), so *every* decoded frame clears it on
      both sides. The native side is paced to the clip's own rate for the same
      reason.
    * The join key is `pts`: the plugin dates lines from RTP timestamps and the NIF
      from the container's, so the two differ by a constant the alignment search
      recovers.

  The motion gate is off, because a gated frame re-reports the last pass's boxes and
  which frame that was is decided per process — one frame lost to RTP would move the
  boxes for every gated frame after it, on one side only. So no run has ever carried
  an `observation_kind` of `"tracked"`; what covers the seed rule instead is both
  producers calling the same `cairn_detect::emit::seeds_from`.
  """

  alias Cairn.Native
  alias Cairn.Native.Config
  alias Cairn.Native.Observations
  alias Cairn.Observation
  alias Cairn.Pipeline.SampleGate
  alias Cairn.PluginProtocol

  @default_plugin "plugins/cairn-detect/target/release/cairn-detect"
  @feed_py "plugins/cairn-detect/verify/feed.py"

  # Six orders of magnitude under `round_to(score, 3)`, five under
  # `round_to(bbox, 4)`. See the moduledoc.
  @default_tolerance 1.0e-9
  @default_sample_fps 30
  @default_min_score %{"default" => 0.3}
  @default_udp_port 17_950
  # Below this share of the plugin's frames matched on the NIF side, the two runs
  # are not comparable and a clean object diff means nothing.
  @default_coverage 0.95

  @camera_id "parity"
  @epoch "01K0PARITY000000000000000"
  @control %{
    "spec" => "cairn.plugin",
    "version" => 1,
    "type" => "stream.started",
    "camera_id" => @camera_id,
    "stream_epoch" => @epoch,
    "rtp" => %{"clock_rate" => 90_000}
  }

  @type report :: %{
          clip: Path.t(),
          verdict: :parity | :divergence | :ambiguous_alignment,
          expected_frames: non_neg_integer(),
          plugin_frames: non_neg_integer(),
          native_frames: non_neg_integer(),
          matched: non_neg_integer(),
          plugin_only: non_neg_integer(),
          plugin_outside: non_neg_integer(),
          native_only: non_neg_integer(),
          objects: non_neg_integer(),
          pts_offset: integer(),
          alignment: %{agreed: non_neg_integer(), probes: non_neg_integer(), margin: integer()},
          coverage: float(),
          native_share: float(),
          mismatches: [map()],
          expected_differences: map()
        }

  @doc """
  Compare every clip, returning one report each.

  Options: `:model` (required), `:labels`, `:input_size`, `:model_profile`,
  `:plugin` (binary path), `:min_score`, `:sample_fps`, `:tolerance`,
  `:udp_port`, `:work_dir`, `:out` (a directory to dump both sides as ndjson
  into), `:max_frames` (trim the native feed — the CI-sized run),
  `:coverage`, and `:log` (a 1-arity reporter; the mix task passes one that
  writes to standard output).
  """
  @spec run([Path.t()], keyword()) :: [report()]
  def run(clips, opts) do
    opts = defaults(opts)

    on_report = Keyword.fetch!(opts, :on_report)

    clips
    |> Enum.with_index()
    |> Enum.map(fn {clip, index} ->
      # A fresh port per clip: the previous plugin may still be shutting down, and a
      # socket it has not released would silently take the feed.
      report = compare(clip, Keyword.update!(opts, :udp_port, &(&1 + index * 2)))
      # Per clip, so an interrupted run of several has still said what it found.
      on_report.(report)
      report
    end)
  end

  @doc "One clip, both producers."
  @spec compare(Path.t(), keyword()) :: report()
  def compare(clip, opts) do
    opts = defaults(opts)
    log = Keyword.fetch!(opts, :log)
    work = Path.join(Keyword.fetch!(opts, :work_dir), Path.basename(clip, Path.extname(clip)))
    File.mkdir_p!(work)

    %{aus: aus, time_base: time_base, frame_ms: frame_ms} = read_clip(clip, work)
    aus = trim(aus, Keyword.get(opts, :max_frames))
    log.("  #{length(aus)} access units, time base #{inspect(time_base)}, ~#{frame_ms} ms/frame")

    plugin = plugin_run(clip, work, opts)
    log.("  plugin: #{length(plugin)} frames")
    native = native_run(aus, time_base, frame_ms, opts)
    log.("  native: #{length(native)} frames")

    dump(Keyword.get(opts, :out), clip, plugin, native)
    report(clip, plugin, native, length(aus), opts)
  end

  # -- the clip ---------------------------------------------------------------

  @doc """
  A clip as the detect branch will hand it over: whole Annex-B access units with
  the container's own pts.

  ffmpeg's `image2` muxer writes one file per packet, which under `-c copy` is one
  per access unit, so the split is its demuxer's and this module parses no
  bitstream. `h264_mp4toannexb` is the filter the RTP feed applies too, because
  SPS/PPS have to be in band.
  """
  @spec read_clip(Path.t(), Path.t()) :: %{
          aus: [{binary(), integer()}],
          time_base: {pos_integer(), pos_integer()},
          frame_ms: pos_integer()
        }
  def read_clip(clip, work) do
    dir = Path.join(work, "au")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)

    {_out, 0} =
      System.cmd(
        "ffmpeg",
        ["-v", "error", "-i", clip, "-c:v", "copy", "-bsf:v", "h264_mp4toannexb"] ++
          ["-f", "image2", "-y", Path.join(dir, "%06d.h264")],
        stderr_to_stdout: true
      )

    time_base = probe_time_base(clip)
    pts = probe_pts(clip)
    files = dir |> File.ls!() |> Enum.sort()

    # Same demuxer, same order, so a length disagreement means one list is not what
    # it is taken to be — which would silently mis-date every access unit.
    if length(files) != length(pts) do
      raise "#{clip}: ffmpeg wrote #{length(files)} access units for #{length(pts)} packets"
    end

    aus = Enum.zip_with(files, pts, fn file, pts -> {File.read!(Path.join(dir, file)), pts} end)

    %{aus: aus, time_base: time_base, frame_ms: frame_ms(pts, time_base)}
  end

  defp probe_time_base(clip) do
    {out, 0} =
      System.cmd("ffprobe", [
        "-v",
        "error",
        "-select_streams",
        "v:0",
        "-show_entries",
        "stream=time_base",
        "-of",
        "default=nw=1:nk=1",
        clip
      ])

    [num, den] = out |> String.trim() |> String.split("/") |> Enum.map(&String.to_integer/1)
    {num, den}
  end

  defp probe_pts(clip) do
    {out, 0} =
      System.cmd("ffprobe", [
        "-v",
        "error",
        "-select_streams",
        "v:0",
        "-show_entries",
        "packet=pts",
        "-of",
        "default=nw=1:nk=1",
        clip
      ])

    out |> String.split("\n", trim: true) |> Enum.map(&String.to_integer/1)
  end

  defp frame_ms([first, second | _rest], {num, den}),
    do: max(round((second - first) * 1000 * num / den), 1)

  defp frame_ms(_pts, _time_base), do: 50

  defp trim(aus, nil), do: aus
  defp trim(aus, max), do: Enum.take(aus, max)

  # -- the plugin path --------------------------------------------------------

  defp plugin_run(clip, work, opts) do
    stderr = Path.join(work, "plugin.stderr")
    port = start_plugin(stderr, opts)

    try do
      await_up(stderr, port)
      feed = Task.async(fn -> feed(clip, Keyword.fetch!(opts, :udp_port), opts) end)
      lines = collect(port, [])
      Task.await(feed, :infinity)

      for line <- lines,
          {:objects, %Observation{} = observation} <- [PluginProtocol.decode_line(line, :camera)],
          do: observation
    after
      Port.close(port)
    end
  end

  defp start_plugin(stderr, opts) do
    argv =
      [
        Keyword.fetch!(opts, :plugin),
        "--model",
        Keyword.fetch!(opts, :model),
        "--camera-id",
        @camera_id,
        "--udp-port",
        to_string(Keyword.fetch!(opts, :udp_port)),
        "--backend",
        "ort",
        "--decoder",
        "sw",
        "--sample-fps",
        to_string(Keyword.fetch!(opts, :sample_fps)),
        "--min-score-json",
        Jason.encode!(Keyword.fetch!(opts, :min_score))
      ] ++
        flag("--labels", opts[:labels]) ++
        flag("--input-size", opts[:input_size]) ++
        flag("--model-profile", opts[:model_profile]) ++
        flag("--embedder-model", opts[:embedder_model])

    # `exec` so the child is the plugin and not a shell holding it: shutdown is EOF on
    # stdin, which `Port.close/1` delivers only to what the port is attached to.
    # stderr goes to a file because the port carries ndjson and nothing else.
    command = "exec " <> Enum.map_join(argv, " ", &quote_arg/1) <> " 2> " <> quote_arg(stderr)

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [:binary, :exit_status, args: ["-c", command]])

    # The plugin emits no `frame.objects` before it is told an epoch, and EOF on stdin
    # exits it, so the port has to stay open for the run.
    Port.command(port, Jason.encode!(@control) <> "\n")
    port
  end

  # The model loads before the RTP listener opens, so packets sent into that gap are
  # gone. The `up:` line rather than a sleep, because how long the load takes is the
  # model's business.
  defp await_up(stderr, port, waited \\ 0) do
    cond do
      File.exists?(stderr) and File.read!(stderr) =~ "cairn-detect up:" ->
        :ok

      waited > 120_000 ->
        raise "cairn-detect never came up: #{inspect(File.read(stderr))}"

      true ->
        receive do
          {^port, {:exit_status, status}} ->
            raise "cairn-detect exited #{status} before coming up: #{inspect(File.read(stderr))}"
        after
          100 -> await_up(stderr, port, waited + 100)
        end
    end
  end

  defp feed(clip, udp_port, opts) do
    duration = Keyword.fetch!(opts, :feed_duration)

    {_out, 0} =
      System.cmd(
        System.find_executable("python3") || raise("python3 is not on PATH"),
        [@feed_py, "--clip", clip, "--port", to_string(udp_port), "--loops", "0"] ++
          ["--duration", to_string(duration)],
        stderr_to_stdout: true
      )
  end

  # A quiet window ends the run because ffmpeg's exit is not the last line: the plugin
  # is still draining its inference queue.
  defp collect(port, acc, partial \\ "") do
    receive do
      {^port, {:data, chunk}} ->
        {lines, partial} = split_lines(partial <> chunk)
        collect(port, Enum.reverse(lines, acc), partial)

      {^port, {:exit_status, _status}} ->
        Enum.reverse(acc)
    after
      5_000 -> Enum.reverse(acc)
    end
  end

  defp split_lines(buffer) do
    case String.split(buffer, "\n") do
      [partial] -> {[], partial}
      parts -> {Enum.drop(parts, -1), List.last(parts)}
    end
  end

  # -- the NIF path -----------------------------------------------------------

  defp native_run(aus, time_base, frame_ms, opts) do
    unless Native.available?() do
      raise "cairn-native is not loaded (#{inspect(Native.load_error())}) — " <>
              "cargo build --release in plugins/cairn-native and copy " <>
              "libcairn_native.so into priv/native/"
    end

    unless CairnOrt.available?() do
      raise "cairn-ort is not loaded (#{inspect(CairnOrt.load_error())}) — " <>
              "cargo build --release in plugins/cairn-ort and copy " <>
              "libcairn_ort.so into priv/native/"
    end

    {:ok, config} =
      Config.normalize(
        model: Keyword.fetch!(opts, :model),
        labels: opts[:labels],
        input_size: opts[:input_size],
        model_profile: opts[:model_profile],
        embedder_model: opts[:embedder_model],
        backend: "ort",
        decoder: "sw",
        sample_fps: Keyword.fetch!(opts, :sample_fps)
      )

    {:ok, params} =
      Config.stream_params(min_score: Keyword.fetch!(opts, :min_score), stream_epoch: @epoch)

    sample_fps = Keyword.fetch!(opts, :sample_fps)
    {:ok, engine} = CairnOrt.init(config)

    # The exact seam `Cairn.Native.Host.open_decoder/4` crosses: the engine's
    # resolved spec, as terms, plus the decode config.
    spec = CairnOrt.engine_spec(engine)

    decode_params = %{
      decoder: "sw",
      width: spec.width,
      height: spec.height,
      encoding: spec.encoding,
      resize: spec.resize,
      resize_pad: spec.resize_pad,
      # Absent, as it is for every software decode: the parity harness compares
      # this path against the plugin's, and the plugin reads its geometry from
      # a container the same way this decoder reads it from the first SPS.
      source_width: nil,
      source_height: nil,
      motion_json: params.motion_json,
      sample_fps: sample_fps
    }

    {:ok, decoder} = Native.open_decoder(@camera_id, decode_params)
    {:ok, stream} = CairnOrt.open_stream(engine, @camera_id, params)

    try do
      push_all(
        decoder,
        stream,
        aus,
        time_base,
        pace_ms(frame_ms, opts),
        SampleGate.new(sample_fps)
      )
    after
      Native.close_decoder(decoder)
      CairnOrt.close_stream(stream)
    end
  end

  # The gate measures the gap between the instants two pushes are *entered* at, so a
  # feed faster than the sample interval would thin frames the plugin's real-time feed
  # keeps. The clip's own rate already is slower.
  defp pace_ms(frame_ms, opts) do
    interval = div(1000, Keyword.fetch!(opts, :sample_fps)) + 5
    max(frame_ms, interval)
  end

  # The element sequence, without the elements: rate-gate before the decode
  # call, spend on a completed frame, hand a sampled frame — payload plus the
  # very metadata `Cairn.Pipeline.Decoder` would put on the buffer — to the
  # inference half.
  defp push_all(decoder, stream, aus, time_base, pace_ms, gate) do
    aus
    |> Enum.flat_map_reduce({nil, gate}, fn {au, pts}, {previous, gate} ->
      sleep_until(previous, pace_ms)
      started = System.monotonic_time(:millisecond)
      now = System.monotonic_time(:nanosecond)
      sample = SampleGate.open?(gate, now)
      {:ok, {completed, frame}} = Native.decode_au(decoder, au, pts, sample)
      gate = if sample and completed, do: SampleGate.spend(gate, now), else: gate
      {infer(stream, frame, time_base), {started, gate}}
    end)
    |> elem(0)
    |> Enum.map(&Observations.from_frame(&1, @camera_id, @epoch))
  end

  defp infer(_stream, nil, _time_base), do: []

  defp infer(stream, frame, time_base) do
    meta =
      Map.take(frame, [:width, :height, :orig_width, :orig_height, :pts, :observed_at_ms, :motion])

    {:ok, {frames, []}} = CairnOrt.push_frame(stream, frame.payload, meta, time_base)
    frames
  end

  defp sleep_until(nil, _pace_ms), do: :ok

  defp sleep_until(previous, pace_ms) do
    case previous + pace_ms - System.monotonic_time(:millisecond) do
      remaining when remaining > 0 -> Process.sleep(remaining)
      _elapsed -> :ok
    end
  end

  # -- the comparison ---------------------------------------------------------

  @doc """
  The comparison itself: two runs' observations in, one report out. Public because it
  is the whole of `compare/2` that needs neither a NIF, a plugin, ffmpeg nor a clip.
  """
  @spec report(Path.t(), [Observation.t()], [Observation.t()], non_neg_integer(), keyword()) ::
          report()
  def report(clip, plugin, native, expected, opts) do
    opts = defaults(opts)
    tolerance = Keyword.fetch!(opts, :tolerance)
    {offset, alignment} = align(plugin, native, tolerance)
    {matched, plugin_only, native_only, outside} = join(plugin, native, offset)
    mismatches = Enum.flat_map(matched, &frame_diff(&1, offset, tolerance))
    coverage = share(length(matched), length(matched) + length(plugin_only))

    %{
      clip: clip,
      verdict:
        verdict(mismatches, length(matched), coverage, Keyword.fetch!(opts, :coverage), alignment),
      expected_frames: expected,
      plugin_frames: length(plugin),
      native_frames: length(native),
      matched: length(matched),
      plugin_only: length(plugin_only),
      plugin_outside: length(outside),
      native_only: length(native_only),
      objects: Enum.sum(Enum.map(matched, fn {a, _b} -> length(a.objects) end)),
      pts_offset: offset,
      alignment: alignment,
      coverage: coverage,
      native_share: share(length(native), expected),
      mismatches: mismatches,
      expected_differences: expected_differences(matched)
    }
  end

  defp share(_part, 0), do: 0.0
  defp share(part, whole), do: part / whole

  # `coverage` is the share of the plugin's frames *inside the window the NIF run
  # covers* that the NIF also produced, not the share of the clip: RTP loses frames
  # the NIF path cannot, and `max_frames` shortens the window on purpose. The floor on
  # `matched` is so a run that lined up on almost nothing cannot pass by having
  # nothing to disagree about.
  #
  # A margin of 0 gets its own verdict rather than `:divergence`: nothing was found to
  # differ, the run just did not compare the frames it claims to have.
  defp verdict([], matched, coverage, floor, %{margin: margin})
       when matched >= 25 and coverage >= floor do
    if margin > 0, do: :parity, else: :ambiguous_alignment
  end

  defp verdict(_mismatches, _matched, _coverage, _floor, _alignment), do: :divergence

  @doc """
  The pts offset that carries the plugin's series onto the NIF's, and how sure the
  search is of it.

  Every native frame is a candidate partner for the plugin's first few, because a
  feed that lost its opening GOP starts a whole second of frames in.

  Ranked by agreement and never by how many frames pair up: an earlier version
  maximised paired frames and produced a false divergence, because the pair count is
  a property of the two pts *ranges* — which a `max_frames` trim moves around — so
  maximising it slid the plugin's series into the middle of the NIF's range, and a
  wrong offset pairs each frame with its neighbour, which on a slow scene looks
  nearly right. An offset one frame out agrees on nothing at all.

  A `margin` of 0 means several offsets fit equally and the pairing is a coin flip.
  It is reported rather than refused, so a caller can dump both runs and look;
  `report/5` is where a coin flip stops being a pass.
  """
  @spec align([Observation.t()], [Observation.t()], float()) ::
          {integer(), %{agreed: non_neg_integer(), probes: non_neg_integer(), margin: integer()}}
  def align(plugin, native, tolerance) do
    by_pts = Map.new(native, &{&1.pts, &1})
    # Four anchors so a corrupt or missing first plugin frame cannot take the true
    # offset out of the candidate set.
    candidates = for a <- Enum.take(plugin, 4), b <- native, uniq: true, do: a.pts - b.pts
    probes = probes(plugin)

    scored =
      candidates
      |> Enum.map(fn offset -> {offset, agreement(probes, by_pts, offset, tolerance)} end)
      |> Enum.sort_by(fn {offset, {agreed, paired}} -> {-agreed, -paired, abs(offset)} end)

    case scored do
      [] ->
        {0, %{agreed: 0, probes: length(probes), margin: 0}}

      [{offset, {agreed, _paired}} | rest] ->
        runner_up =
          Enum.max(Enum.map(rest, fn {_offset, {agreed, _}} -> agreed end), &>=/2, fn -> 0 end)

        {offset, %{agreed: agreed, probes: length(probes), margin: agreed - runner_up}}
    end
  end

  # Spread across the run, not taken from the front: an offset that agrees over one
  # still stretch has to disagree somewhere else.
  defp probes(plugin) do
    case div(length(plugin), 40) do
      0 -> plugin
      step -> Enum.take_every(plugin, step)
    end
  end

  defp agreement(probes, by_pts, offset, tolerance) do
    Enum.reduce(probes, {0, 0}, fn a, {agreed, paired} ->
      case Map.fetch(by_pts, a.pts - offset) do
        {:ok, b} -> {agreed + if(objects_diff(a, b, tolerance) == [], do: 1, else: 0), paired + 1}
        :error -> {agreed, paired}
      end
    end)
  end

  # `outside` is the plugin frames the NIF run never covered — a `max_frames` trim, or
  # the tail of a clip the feed outlasted. Not evidence about either producer, so they
  # are set aside rather than held against the coverage the verdict reads.
  defp join(plugin, native, offset) do
    by_pts = Map.new(native, &{&1.pts, &1})
    window = Enum.min_max_by(native, & &1.pts, fn -> {nil, nil} end)

    {inside, outside} = Enum.split_with(plugin, &in_window?(&1.pts - offset, window))
    {matched, plugin_only} = Enum.split_with(inside, &Map.has_key?(by_pts, &1.pts - offset))

    matched = Enum.map(matched, &{&1, Map.fetch!(by_pts, &1.pts - offset)})
    seen = MapSet.new(matched, fn {_a, b} -> b.pts end)
    {matched, plugin_only, Enum.reject(native, &MapSet.member?(seen, &1.pts)), outside}
  end

  defp in_window?(_pts, {nil, nil}), do: false
  defp in_window?(pts, {first, last}), do: pts >= first.pts and pts <= last.pts

  defp frame_diff({%Observation{} = a, %Observation{} = b}, offset, tolerance) do
    envelope =
      for {field, x, y} <- [
            {:camera_id, a.camera_id, b.camera_id},
            {:epoch, a.epoch, b.epoch},
            {:time_base, a.time_base, b.time_base},
            {:protocol, a.protocol, b.protocol},
            {:time_quality, a.time_quality, b.time_quality},
            {:invalid_objects, a.invalid_objects, b.invalid_objects},
            {:ended_tracks, a.ended_tracks, b.ended_tracks},
            {:pts, a.pts - offset, b.pts},
            {:media_ms, Observation.media_ms(a.pts - offset, a.time_base), b.media_ms}
          ],
          x != y,
          do: %{pts: b.pts, kind: :envelope, field: field, plugin: x, native: y}

    envelope ++ objects_diff(a, b, tolerance)
  end

  # A length mismatch is reported whole: pairing objects positionally past a missing
  # one turns one divergence into a cascade of unrelated ones.
  defp objects_diff(a, b, tolerance) do
    if length(a.objects) != length(b.objects) do
      [%{pts: b.pts, kind: :object_count, plugin: a.objects, native: b.objects}]
    else
      a.objects
      |> Enum.zip(b.objects)
      |> Enum.with_index()
      |> Enum.flat_map(fn {{x, y}, index} -> object_diff(x, y, index, b.pts, tolerance) end)
    end
  end

  defp object_diff(x, y, index, pts, tolerance) do
    same? =
      x.label == y.label and x.observation_kind == y.observation_kind and
        x.track_id == y.track_id and Map.get(x, :embedding) == Map.get(y, :embedding) and
        close?(x.score, y.score, tolerance) and
        Enum.zip(x.bbox, y.bbox) |> Enum.all?(fn {p, q} -> close?(p, q, tolerance) end)

    if same?,
      do: [],
      else: [%{pts: pts, kind: :object, index: index, plugin: x, native: y}]
  end

  defp close?(x, y, tolerance), do: abs(x - y) <= tolerance

  # The deliberate omissions, counted rather than asserted so the caller can insist
  # they are the *only* ones.
  defp expected_differences(matched) do
    %{
      plugin_sequence_present: Enum.count(matched, fn {a, _b} -> is_integer(a.sequence) end),
      native_sequence_nil: Enum.count(matched, fn {_a, b} -> is_nil(b.sequence) end),
      plugin_instance_nil_both:
        Enum.count(matched, fn {a, b} ->
          is_nil(a.plugin_instance) and is_nil(b.plugin_instance)
        end),
      frames: length(matched)
    }
  end

  # -- ndjson dumps -----------------------------------------------------------

  # Both sides in the wire's own shape, so `verify/validate_ndjson.py` and
  # `verify/compare_runs.py` read the NIF run exactly as they read a plugin run.
  defp dump(nil, _clip, _plugin, _native), do: :ok

  defp dump(dir, clip, plugin, native) do
    File.mkdir_p!(dir)
    base = Path.basename(clip, Path.extname(clip))
    write_ndjson(Path.join(dir, base <> ".plugin.ndjson"), plugin)
    write_ndjson(Path.join(dir, base <> ".native.ndjson"), native)
  end

  defp write_ndjson(path, observations) do
    lines =
      observations
      |> Enum.with_index()
      |> Enum.map(fn {observation, index} -> Jason.encode!(wire(observation, index)) <> "\n" end)

    File.write!(path, lines)
  end

  defp wire(%Observation{} = observation, index) do
    %{
      "spec" => "cairn.plugin",
      "version" => 1,
      "type" => "frame.objects",
      "camera_id" => observation.camera_id,
      "stream_epoch" => observation.epoch,
      "sequence" => observation.sequence || index,
      "frame" => %{
        "pts" => observation.pts,
        "time_base" => Tuple.to_list(observation.time_base),
        "observed_at" => DateTime.to_iso8601(observation.observed_at)
      },
      "objects" => Enum.map(observation.objects, &wire_object/1)
    }
  end

  defp wire_object(object) do
    wire = %{
      "label" => object.label,
      "score" => object.score,
      "bbox" => object.bbox,
      "observation_kind" => object.observation_kind
    }

    case Map.get(object, :embedding) do
      nil -> wire
      bytes -> Map.put(wire, "embedding", Base.encode64(bytes))
    end
  end

  # -- options ----------------------------------------------------------------

  defp defaults(opts) do
    opts
    |> Keyword.put_new(:plugin, @default_plugin)
    |> Keyword.put_new(:min_score, @default_min_score)
    |> Keyword.put_new(:sample_fps, @default_sample_fps)
    |> Keyword.put_new(:tolerance, @default_tolerance)
    |> Keyword.put_new(:udp_port, @default_udp_port)
    |> Keyword.put_new(:coverage, @default_coverage)
    |> Keyword.put_new(:feed_duration, 120)
    |> Keyword.put_new(:work_dir, Path.join(System.tmp_dir!(), "cairn-parity"))
    |> Keyword.put_new(:log, fn _message -> :ok end)
    |> Keyword.put_new(:on_report, fn _report -> :ok end)
  end

  defp flag(_name, nil), do: []
  defp flag(name, value), do: [name, to_string(value)]

  defp quote_arg(value), do: "'" <> String.replace(to_string(value), "'", ~S('\'')) <> "'"
end
