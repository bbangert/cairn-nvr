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
    * `motion` — the motion measurement (`t:Cairn.Native.motion_verdict/0`),
      when the gate is configured: measured here because this is the only
      element holding pixels, acted on downstream where the model is.

  `buffer.pts` is the *frame's* timestamp (reordering means it is not always
  the access unit's), `nil` for a frame the decoder could not date.

  ## Rate and flow

  Every access unit is decoded — a stateful decoder needs its references —
  but only frames clearing `Cairn.Pipeline.SampleGate` (`sample_fps`, decided
  by the `Cairn.Native.Host.open_decoder/3` reply) are converted and emitted:
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
  does for its half. Two liveness notes: the `Host.open_decoder/3` call is a
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
       pending: nil,
       demand: 0,
       sampled: 0,
       emitted: 0,
       replaced: 0,
       errors: 0
     }}
  end

  @impl true
  def handle_playing(ctx, state) do
    {[demand: {:input, 1}], ensure_decoder(state, ctx)}
  end

  # Swallowed, not forwarded (the filter default would forward it onto the
  # RawVideo pad): the output format is minted here from the first decoded
  # frame's geometry, which the decoder learns from the SPS — nothing upstream
  # declares it.
  @impl true
  def handle_stream_format(:input, %Membrane.H264{}, _ctx, state), do: {[], state}

  @impl true
  def handle_buffer(:input, %Buffer{pts: pts} = buffer, ctx, state) when is_integer(pts) do
    state = ensure_decoder(state, ctx)
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
        admit(state, frame)

      {:error, {reason, message}} when reason in @fatal ->
        Logger.error(
          "camera #{state.camera_id}: decoder is #{reason} (#{message}); reopening after cooldown"
        )

        {[], state |> drop_decoder(ctx) |> reopen_later()}

      {:error, _transient} ->
        {[], %{state | errors: state.errors + 1}}
    end
  end

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

    buffer = %Buffer{
      pts: frame.pts,
      payload: frame.payload,
      metadata:
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
    case Host.open_decoder(state.host, state.camera_id, state.params) do
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
            retry_at: nil
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
