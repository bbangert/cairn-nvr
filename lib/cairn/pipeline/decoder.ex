defmodule Cairn.Pipeline.Decoder do
  @moduledoc """
  Decode and resize as their own element: AU-aligned H.264 in, sampled
  content-rect RGB frames out as plain buffers — the seam that makes the
  detection stages composable (D-C2).

  ## The payload convention

  `payload` is tightly packed RGB24 rows, and the stream format is
  `%Membrane.RawVideo{pixel_format: :RGB}` — never a custom struct, never a
  tensor: raw bytes are what every element in the ecosystem can slice. What
  crosses is the *content rectangle* — the frame aspect-preserved into the
  model's input rect with the letterbox padding left off — and
  `buffer.metadata` carries the maths every consumer otherwise re-derives:

    * `orig_width`/`orig_height` — the geometry the camera sent (on a
      hardware-decode path the payload is already GPU-scaled, so this is not
      the payload's own size);
    * `scale_x`/`scale_y` — content pixels per source pixel, per axis (the
      axes differ: each scaled side is floored to an even pixel count
      independently);
    * `pad_w`/`pad_h` — what the model rect adds around the content, on the
      right and bottom only (the content sits top-left);
    * `observed_at_ms` — wall clock when the frame cleared the sample gate,
      captured here because a frame can wait behind a busy model pass
      downstream;
    * `stream_epoch` — the session the frame belongs to, carried over from the
      access unit it was decoded from (`Cairn.Pipeline.EpochTagger` stamps it
      at production time); `nil` under a producer that tags nothing;
    * `motion` — the motion measurement (`t:Cairn.Native.motion_verdict/0`),
      when the *decoder* was asked to measure (`stream_params.motion_json`);
      absent otherwise. `Cairn.Pipeline.Camera` no longer asks — the
      measurement is `Cairn.Pipeline.MotionGate`'s now (D-C3), and the NIF
      path stays as its parity reference — but the contract holds for any
      producer that does.

  `buffer.pts` is the *frame's* timestamp (reordering means it is not always
  the access unit's), `nil` for a frame the decoder could not date.

  ## Rate and flow

  Every access unit is decoded — a stateful decoder needs its references —
  but only frames clearing `Cairn.Pipeline.SampleGate` (`sample_fps`, decided
  by the `Cairn.Native.Host.open_decoder/4` reply) are converted and emitted:
  sampling decides model passes, not decode. Both pads are `:manual`, and the
  element demands access units at line rate regardless of downstream demand —
  one AU per `decode_au`, one slot for the emitted frame. A frame the sink
  has no demand for yet is replaced by a newer one (newest wins: frames,
  unlike access units, owe nothing to their successors), so memory stays O(1)
  and `Cairn.Pipeline.Picker` upstream sheds only when *decode* falls behind
  the line rate.

  The native decoder opens against `Cairn.Native.Host`'s engine (same model,
  same resolved input spec as the inference stream) and reopens on a
  cooldown after stream-fatal errors, exactly as `Cairn.Pipeline.Inference`
  does for its half. Two liveness notes: the `Host.open_decoder/4` call is a
  plain `GenServer.call` — the host's liveness is application-supervised (it
  sits outside every camera's tree), so a missing host is a boot-order fault
  that should crash this element, not a state to retry around. And
  `Membrane.ResourceGuard.cleanup/2` is asynchronous: a reopen can overlap
  the previous handle's native close, which is safe here precisely because a
  decoder handle carries no camera-id claim — two decoders for one camera
  merely waste work for a moment.
  """

  use Membrane.Filter

  require Logger

  alias Cairn.Native.Host
  alias Cairn.Pipeline.SampleGate
  alias Membrane.Buffer

  def_input_pad(:input,
    accepted_format: %Membrane.H264{alignment: :au},
    flow_control: :manual,
    demand_unit: :buffers
  )

  def_output_pad(:output,
    accepted_format: %Membrane.RawVideo{pixel_format: :RGB},
    flow_control: :manual
  )

  def_options(
    camera_id: [spec: String.t()],
    host: [spec: atom(), default: Cairn.Native.Host],
    stream_params: [
      spec: map(),
      default: %{},
      description:
        "`Cairn.Native.Config.stream_params/1` vocabulary; only `motion_json` matters here"
    ],
    reopen_cooldown_ms: [
      spec: non_neg_integer(),
      default: 5_000,
      description: "How long a refused open or a lost decoder waits before the next attempt"
    ]
  )

  # `Cairn.Native.Host`'s stream-fatal class: the handle is unusable and the
  # remedy is reopening. Engine-fatal reasons cannot come back from a decoder —
  # it never touches the model.
  @fatal [:closed, :poisoned, :panicked]

  # Access units a decoder may complete nothing from before it is called blind.
  # Comfortably past a fleet GOP (the longest measured is 5 s, ~150 frames) so
  # that a stream joined mid-GOP, which really does decode nothing until the
  # next IDR, never trips it.
  @blind_after 400

  @impl true
  def handle_init(_ctx, opts) do
    {[],
     %{
       camera_id: opts.camera_id,
       host: opts.host,
       params: opts.stream_params,
       cooldown_ms: opts.reopen_cooldown_ms,
       decoder: :closed,
       gate: nil,
       retry_at: nil,
       format: nil,
       source: nil,
       epoch: nil,
       pending: nil,
       demand: 0,
       sampled: 0,
       emitted: 0,
       replaced: 0,
       errors: 0,
       since_open: 0,
       completed: 0,
       blind?: false
     }}
  end

  # No decoder yet: the H.264 stream format carries the source geometry a
  # hardware decoder needs at open, and Membrane guarantees it arrives before
  # the first buffer.
  @impl true
  def handle_playing(_ctx, state) do
    {[demand: {:input, 1}], state}
  end

  # Swallowed, not forwarded (the filter default would forward it onto the
  # RawVideo pad): the output format is minted here from the decoded frame's
  # geometry, which is the model's rect and not the camera's.
  #
  # The geometry is kept, though. A decoder built for one source geometry is
  # wrong for another, so a camera reconfigured mid-stream gets a new decoder
  # rather than a new SPS through an old one — immediately, not on the fault
  # cooldown, since this is a reconfiguration and not a failure. That includes
  # a decoder learning its geometry for the first time (nil -> real): the
  # SPS-taught decoder it replaces was healthy, and one reopen at the moment a
  # parser starts declaring is the cost of never running hardware decode
  # against a geometry nobody confirmed.
  @impl true
  def handle_stream_format(:input, %Membrane.H264{} = format, ctx, state) do
    known = state.source

    case source_of(format) do
      ^known -> {[], state}
      source -> {[], state |> reopen_for(source, ctx) |> ensure_decoder(ctx)}
    end
  end

  defp source_of(%Membrane.H264{width: w, height: h}) when is_integer(w) and is_integer(h),
    do: {w, h}

  # A parser that declared no geometry leaves the decoder to learn it from the
  # SPS, which is what software decode did for three phases and hardware decode
  # cannot do at all.
  defp source_of(%Membrane.H264{}), do: nil

  # Nothing is open, but the cooldown still clears: the failed open this
  # camera is waiting out was made for the OLD geometry, and its verdict says
  # nothing about the new one — `ensure_decoder` retries on the next callback.
  defp reopen_for(%{decoder: :closed} = state, source, _ctx),
    do: %{state | source: source, retry_at: nil}

  defp reopen_for(state, source, ctx) do
    Logger.info(
      "camera #{state.camera_id}: source geometry #{inspect(state.source)} -> " <>
        "#{inspect(source)}; reopening the decoder"
    )

    state |> drop_decoder(ctx) |> Map.put(:source, source) |> Map.put(:retry_at, nil)
  end

  @impl true
  def handle_buffer(:input, %Buffer{pts: pts} = buffer, ctx, state) when is_integer(pts) do
    state = %{ensure_decoder(state, ctx) | epoch: buffer.metadata[:stream_epoch]}
    {actions, state} = decode(state, ctx, buffer)
    # The next access unit is demanded whatever became of this one: decode
    # runs at line rate, and downstream demand only gates the emit.
    {actions ++ [demand: {:input, 1}], state}
  end

  # No pts is no timestamp to date a detection with, so it never reaches the
  # NIF (whose contract is an integer) — the same refusal
  # `Cairn.Pipeline.Picker` makes upstream in this pipeline, restated here
  # because this element is meant to stand on its own. Counted, so a source
  # that lost its timestamps is visible in `:stats`.
  def handle_buffer(:input, _buffer, _ctx, state) do
    {[demand: {:input, 1}], %{state | errors: state.errors + 1}}
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state) do
    maybe_send(%{state | demand: state.demand + size})
  end

  @impl true
  def handle_parent_notification(:stats, _ctx, state) do
    stats = %{
      sampled: state.sampled,
      emitted: state.emitted,
      replaced: state.replaced,
      errors: state.errors,
      decoder: if(state.decoder == :closed, do: :closed, else: :open)
    }

    {[notify_parent: {:stats, stats}], state}
  end

  defp decode(%{decoder: :closed} = state, _ctx, _buffer), do: {[], state}

  defp decode(%{decoder: %{ref: ref, module: module}} = state, ctx, buffer) do
    now = System.monotonic_time(:nanosecond)
    sample = SampleGate.open?(state.gate, now)

    case module.decode_au(ref, buffer.payload, buffer.pts, sample) do
      {:ok, {completed, frame}} ->
        state = if sample and completed, do: spend(state, now), else: state
        admit(count(state, completed), frame)

      {:error, {reason, message}} when reason in @fatal ->
        Logger.error(
          "camera #{state.camera_id}: decoder is #{reason} (#{message}); reopening after cooldown"
        )

        {[], state |> drop_decoder(ctx) |> reopen_later()}

      {:error, _transient} ->
        {[], count(%{state | errors: state.errors + 1}, false)}
    end
  end

  # A decoder that has never completed a frame is the one failure this element
  # has no other symptom for. Every per-frame decode error is *tolerated* by
  # design — joining mid-GOP means feeding references that never arrived — so a
  # decoder that fails all of them looks exactly like a stream that has not
  # resynced yet, and says so once per fifty frames in the crate's log and
  # nowhere else. That is how a QCS6490 board ran 761 access units to zero
  # frames (`research/board-first-light.md`): the hardware decoder opened, and
  # nothing above it could tell.
  #
  # Said once per open, not per frame, and not a restart: the remedy is an
  # operator's (a decoder this host cannot really run), and reopening into the
  # same wrong decoder would only bury the line.
  defp count(%{completed: 0, blind?: false} = state, false) do
    state = %{state | since_open: state.since_open + 1}

    if state.since_open >= @blind_after do
      Logger.error(
        "camera #{state.camera_id}: the decoder has completed no frames in " <>
          "#{state.since_open} access units — it opened but is decoding nothing; " <>
          "detection is off for this camera"
      )

      %{state | blind?: true}
    else
      state
    end
  end

  defp count(state, false), do: %{state | since_open: state.since_open + 1}

  defp count(state, true),
    do: %{state | since_open: state.since_open + 1, completed: state.completed + 1}

  defp spend(state, now),
    do: %{state | gate: SampleGate.spend(state.gate, now), sampled: state.sampled + 1}

  defp admit(state, nil), do: {[], state}

  defp admit(%{pending: pending} = state, frame) do
    # Newest wins: a frame waiting out a busy model pass is strictly worth
    # less than the one that just arrived, and unlike an access unit it owes
    # nothing to what follows it.
    state = if pending == nil, do: state, else: %{state | replaced: state.replaced + 1}
    maybe_send(%{state | pending: frame})
  end

  # The rendezvous, as in `Cairn.Pipeline.Picker`: whichever of demand and a
  # pending frame arrives second emits.
  defp maybe_send(%{pending: frame, demand: demand} = state) when frame != nil and demand > 0 do
    format = %Membrane.RawVideo{
      width: frame.width,
      height: frame.height,
      framerate: nil,
      pixel_format: :RGB,
      aligned: true
    }

    metadata =
      Map.take(frame, [
        :orig_width,
        :orig_height,
        :scale_x,
        :scale_y,
        :pad_w,
        :pad_h,
        :observed_at_ms,
        :motion
      ])

    buffer = %Buffer{
      pts: frame.pts,
      payload: frame.payload,
      # The epoch of the last access unit fed in, not of the picture: decode
      # reordering can emit a frame belonging to the previous session just
      # after the boundary. At most one frame is mis-tagged, and the boundary
      # makes it moot — the new session opens on an IDR, and an old-session
      # straggler ages out at the staleness gate.
      metadata: Map.put(metadata, :stream_epoch, state.epoch)
    }

    actions =
      if state.format == format,
        do: [buffer: {:output, buffer}],
        else: [stream_format: {:output, format}, buffer: {:output, buffer}]

    {actions,
     %{state | pending: nil, demand: state.demand - 1, emitted: state.emitted + 1, format: format}}
  end

  defp maybe_send(state), do: {[], state}

  # -- the native decoder's lifecycle ------------------------------------------

  defp ensure_decoder(%{decoder: %{}} = state, _ctx), do: state

  defp ensure_decoder(%{retry_at: retry_at} = state, ctx) when is_integer(retry_at) do
    if now_ms() >= retry_at, do: open(state, ctx), else: state
  end

  defp ensure_decoder(state, ctx), do: open(state, ctx)

  defp open(state, ctx) do
    case Host.open_decoder(state.host, state.camera_id, state.params, state.source) do
      {:ok, %{ref: ref, module: module, sample_fps: sample_fps}} ->
        # Registered per open, so a crash between here and teardown still
        # frees the decoder — a hardware one holds GPU surfaces.
        Membrane.ResourceGuard.register(
          ctx.resource_guard,
          fn -> module.close_decoder(ref) end,
          tag: {:decoder, ref}
        )

        %{
          state
          | decoder: %{ref: ref, module: module},
            gate: SampleGate.new(sample_fps),
            retry_at: nil,
            since_open: 0,
            completed: 0,
            blind?: false
        }

      {:error, reason} ->
        # Not fatal to the session: the engine may still be loading its model,
        # and the next access unit past the cooldown tries again.
        Logger.warning("camera #{state.camera_id}: no native decoder (#{inspect(reason)})")
        reopen_later(state)
    end
  end

  # `cleanup/2` both runs the registered close and unregisters it, so a
  # reopen cannot stack a second guard for a handle that is already gone.
  defp drop_decoder(%{decoder: %{ref: ref}} = state, ctx) do
    Membrane.ResourceGuard.cleanup(ctx.resource_guard, {:decoder, ref})
    %{state | decoder: :closed, gate: nil}
  end

  defp reopen_later(state) do
    %{state | errors: state.errors + 1, retry_at: now_ms() + state.cooldown_ms}
  end

  # Monotonic milliseconds, which start negative on the BEAM: nothing here may
  # read the value as a sign.
  defp now_ms, do: System.monotonic_time(:millisecond)
end
