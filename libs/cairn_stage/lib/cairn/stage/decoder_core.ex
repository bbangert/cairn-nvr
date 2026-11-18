defmodule Cairn.Stage.DecoderCore do
  @moduledoc """
  A decode element's board-independent lifecycle: opening, reopening and
  refusing the decoder, the sample gate, and the one-frame output slot. The
  element keeps its pads, options and input format, implements this
  behaviour, and holds this struct as its state; each of its Membrane
  callbacks hands over to one function here.

  Every access unit is decoded — a stateful decoder needs its references —
  but only frames clearing `Cairn.Stage.SampleGate` (`sample_fps`, from the
  `c:open_decoder/2` reply) are converted and emitted: sampling decides model
  passes, not decode. Access units are demanded at line rate regardless of
  downstream demand — one AU per `decode_au`, one slot for the emitted frame.
  A frame the sink has no demand for yet is replaced by a newer one (newest
  wins: frames, unlike access units, owe nothing to their successors), so
  memory stays O(1).

  The decoder reopens on a cooldown after a failed open or a stream-fatal
  error, at once when the source geometry changes, and not at all after a
  refusal until it does. A handle poisoned or panicked three times in a row
  with no frame between is refused too. A decoder that completes nothing in
  its first 400 access units is reported once per open, not restarted.

  `Membrane.ResourceGuard.cleanup/2` is asynchronous: a reopen can overlap
  the previous handle's native close. A `Cairn.Stage.DecoderNif` handle must
  therefore claim nothing per camera — then two decoders for one camera
  merely waste work for a moment.
  """

  require Logger

  alias Cairn.Stage.SampleGate
  alias Membrane.Buffer

  @type source :: {pos_integer(), pos_integer()} | nil

  # `module` is a `Cairn.Stage.DecoderNif` implementation, `sample_fps` the
  # gate's rate. Called in the element's process: a raise crashes the element,
  # and an `{:error, _}` is retried past the cooldown.
  @callback open_decoder(arg :: term(), source()) ::
              {:ok, %{ref: reference(), module: module(), sample_fps: 1..30}}
              | {:error, term()}

  # A refusal comes from `decode_au` after an open that succeeded, so the
  # element hears of it here rather than from `c:open_decoder/2`. Once per
  # refusal.
  @callback decoder_refused(arg :: term(), message :: String.t()) :: term()

  # `frame` is whatever `decode_au` returned; `epoch` came with the last dated
  # access unit. The core sends the stream format only when it changes.
  @callback output(frame :: term(), epoch :: term()) ::
              {stream_format :: struct(), Buffer.t()}

  # A frame replaced before it was output. For a frame that holds a native
  # resource, so it is given back now rather than when the term is collected.
  @callback discard(arg :: term(), frame :: term()) :: term()

  @optional_callbacks discard: 2

  @enforce_keys [:camera_id, :element, :cooldown_ms]
  defstruct [
    :camera_id,
    :element,
    :cooldown_ms,
    arg: nil,
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
    failed: 0,
    blind?: false
  ]

  @type t :: %__MODULE__{}

  # A `Cairn.Stage.DecoderNif`'s stream-fatal class: the handle is unusable and
  # the remedy is reopening, until `@refuse_after` poisoned or panicked
  # handles in a row have yielded no frame. Engine-fatal reasons cannot come
  # back from a decoder — it never touches the model.
  @fatal [:closed, :poisoned, :panicked]
  @refuse_after 3

  # Access units a decoder may complete nothing from before it is called blind.
  # Comfortably past a fleet GOP (the longest measured is 5 s, ~150 frames) so
  # that a stream joined mid-GOP, which really does decode nothing until the
  # next IDR, never trips it.
  @blind_after 400

  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      camera_id: Keyword.fetch!(opts, :camera_id),
      element: Keyword.fetch!(opts, :element),
      arg: Keyword.get(opts, :arg),
      cooldown_ms: Keyword.fetch!(opts, :cooldown_ms)
    }
  end

  # No decoder yet: the input's stream format carries the source geometry a
  # hardware decoder needs at open, and Membrane guarantees it arrives before
  # the first buffer.
  @spec playing(t()) :: {[Membrane.Element.Action.t()], t()}
  def playing(core), do: {[demand: {:input, 1}], core}

  # A decoder built for one source geometry is wrong for another, so a camera
  # reconfigured mid-stream gets a new decoder rather than a new SPS through
  # an old one — immediately, not on the fault cooldown, since this is a
  # reconfiguration and not a failure. That includes a decoder learning its
  # geometry for the first time (nil -> real): the SPS-taught decoder it
  # replaces was healthy, and one reopen at the moment a parser starts
  # declaring is the cost of a decoder never outliving the geometry it was
  # built for.
  @spec stream_format(t(), source(), pid()) :: {[], t()}
  def stream_format(core, source, resource_guard) do
    known = core.source

    case source do
      ^known ->
        {[], core}

      source ->
        core = %{core | failed: 0} |> reopen_for(source, resource_guard)
        {[], ensure_decoder(core, resource_guard)}
    end
  end

  # Nothing is open, but the cooldown still clears: the failed open this
  # camera is waiting out was made for the OLD geometry, and its verdict says
  # nothing about the new one — `stream_format/3` goes on to retry at once.
  defp reopen_for(%{decoder: :closed} = core, source, _guard),
    do: %{core | source: source, retry_at: nil}

  # A refused decoder gets one fresh chance from a genuinely different
  # stream: the refusal was the probe's verdict on the stream it watched,
  # and a reconfiguration means the operator moved something. Still refused
  # there, it goes dark again — bounded by reconfigurations, not keyframes.
  defp reopen_for(%{decoder: :refused} = core, source, _guard),
    do: %{core | decoder: :closed, source: source, retry_at: nil}

  defp reopen_for(core, source, guard) do
    Logger.info(
      "camera #{core.camera_id}: source geometry #{inspect(core.source)} -> " <>
        "#{inspect(source)}; reopening the decoder"
    )

    core |> drop_decoder(guard) |> Map.put(:source, source) |> Map.put(:retry_at, nil)
  end

  @spec buffer(t(), binary(), integer() | nil, term(), pid()) ::
          {[Membrane.Element.Action.t()], t()}
  def buffer(core, payload, pts, epoch, resource_guard) when is_integer(pts) do
    core = %{ensure_decoder(core, resource_guard) | epoch: epoch}
    {actions, core} = decode(core, resource_guard, payload, pts)
    # The next access unit is demanded whatever became of this one: decode
    # runs at line rate, and downstream demand only gates the emit.
    {actions ++ [demand: {:input, 1}], core}
  end

  # No pts is no timestamp to date a detection with, so it never reaches the
  # NIF (whose contract is an integer). Counted, so a source that lost its
  # timestamps is visible in `stats/1`.
  def buffer(core, _payload, _pts, _epoch, _resource_guard) do
    {[demand: {:input, 1}], %{core | errors: core.errors + 1}}
  end

  @spec demand(t(), non_neg_integer()) :: {[Membrane.Element.Action.t()], t()}
  def demand(core, size), do: maybe_send(%{core | demand: core.demand + size})

  @spec stats(t()) :: %{
          sampled: non_neg_integer(),
          emitted: non_neg_integer(),
          replaced: non_neg_integer(),
          errors: non_neg_integer(),
          decoder: :closed | :refused | :open
        }
  def stats(core) do
    %{
      sampled: core.sampled,
      emitted: core.emitted,
      replaced: core.replaced,
      errors: core.errors,
      decoder:
        case core.decoder do
          :closed -> :closed
          :refused -> :refused
          _open -> :open
        end
    }
  end

  defp decode(%{decoder: decoder} = core, _guard, _payload, _pts)
       when decoder in [:closed, :refused],
       do: {[], core}

  defp decode(%{decoder: %{ref: ref, module: module}} = core, guard, payload, pts) do
    now = System.monotonic_time(:nanosecond)
    sample = SampleGate.open?(core.gate, now)

    case module.decode_au(ref, payload, pts, sample) do
      {:ok, {completed, frame}} ->
        core = if sample and completed, do: spend(core, now), else: core
        admit(count(core, completed), frame)

      {:error, {:decoder_refused, message}} ->
        refuse(core, guard, message)

      {:error, {reason, message}} when reason in @fatal ->
        fatal(core, guard, reason, message)

      {:error, _transient} ->
        {[], count(%{core | errors: core.errors + 1}, false)}
    end
  end

  # `:closed` never counts. A decoder answers it only after its own close, and
  # this core issues that only as it lets the handle go, so no handle it still
  # holds reports one: the exclusion is a guard nothing reaches today.
  defp fatal(core, guard, reason, message) do
    failed = if reason == :closed, do: core.failed, else: core.failed + 1

    if failed >= @refuse_after do
      refuse(
        core,
        guard,
        "the decoder failed #{failed} times in a row without a frame " <>
          "(last: #{reason}, #{message})"
      )
    else
      Logger.error(
        "camera #{core.camera_id}: decoder is #{reason} (#{message}); reopening after cooldown"
      )

      {[], %{(core |> drop_decoder(guard) |> reopen_later()) | failed: failed}}
    end
  end

  # Not a fault to cool down from: reopening would fail the same way, so
  # `:refused` (unlike `:closed`) is a state `ensure_decoder` never retries
  # out of; only a new stream format lifts it. The branch goes dark —
  # recording is unaffected — and the reason goes to the element's
  # `c:decoder_refused/2`.
  defp refuse(core, guard, message) do
    Logger.error(
      "camera #{core.camera_id}: #{message} — detection is off for this camera; " <>
        "recording is unaffected"
    )

    core.element.decoder_refused(core.arg, message)
    {[], core |> drop_decoder(guard) |> Map.put(:decoder, :refused)}
  end

  # A decoder that has never completed a frame is the one failure a decode
  # element has no other symptom for. Every per-frame decode error is
  # *tolerated* by design — joining mid-GOP means feeding references that never
  # arrived — so a decoder that fails all of them looks exactly like a stream
  # that has not resynced yet, and `cairn-detect`'s decoder says so once per
  # fifty frames in its own log and nowhere else. That is how a QCS6490 board
  # ran 761 access units to zero frames (`research/board-first-light.md`): the
  # hardware decoder opened, and nothing above it could tell.
  #
  # Said once per open, not per frame, and not a restart: the remedy is an
  # operator's (a decoder this host cannot really run), and reopening into the
  # same wrong decoder would only bury the line.
  defp count(%{completed: 0, blind?: false} = core, false) do
    core = %{core | since_open: core.since_open + 1}

    if core.since_open >= @blind_after do
      Logger.error(
        "camera #{core.camera_id}: the decoder has completed no frames in " <>
          "#{core.since_open} access units — it opened but is decoding nothing; " <>
          "detection is off for this camera"
      )

      %{core | blind?: true}
    else
      core
    end
  end

  defp count(core, false), do: %{core | since_open: core.since_open + 1}

  defp count(core, true),
    do: %{core | since_open: core.since_open + 1, completed: core.completed + 1}

  defp spend(core, now),
    do: %{core | gate: SampleGate.spend(core.gate, now), sampled: core.sampled + 1}

  defp admit(core, nil), do: {[], core}

  defp admit(%{pending: pending} = core, frame) do
    core = %{core | failed: 0}
    # Newest wins: a frame waiting out a busy model pass is strictly worth
    # less than the one that just arrived, and unlike an access unit it owes
    # nothing to what follows it.
    core = if pending == nil, do: core, else: replace(core, pending)
    maybe_send(%{core | pending: frame})
  end

  # The only place a decoded frame is dropped: a reopen or a refusal leaves
  # the pending one to go out on the next demand.
  defp replace(core, pending) do
    if function_exported?(core.element, :discard, 2), do: core.element.discard(core.arg, pending)
    %{core | replaced: core.replaced + 1}
  end

  # The rendezvous: whichever of demand and a pending frame arrives second
  # emits.
  defp maybe_send(%{pending: frame, demand: demand} = core) when frame != nil and demand > 0 do
    {format, buffer} = core.element.output(frame, core.epoch)

    actions =
      if core.format == format,
        do: [buffer: {:output, buffer}],
        else: [stream_format: {:output, format}, buffer: {:output, buffer}]

    {actions,
     %{core | pending: nil, demand: core.demand - 1, emitted: core.emitted + 1, format: format}}
  end

  defp maybe_send(core), do: {[], core}

  defp ensure_decoder(%{decoder: %{}} = core, _guard), do: core

  defp ensure_decoder(%{decoder: :refused} = core, _guard), do: core

  defp ensure_decoder(%{retry_at: retry_at} = core, guard) when is_integer(retry_at) do
    if now_ms() >= retry_at, do: open(core, guard), else: core
  end

  defp ensure_decoder(core, guard), do: open(core, guard)

  defp open(core, guard) do
    case core.element.open_decoder(core.arg, core.source) do
      {:ok, %{ref: ref, module: module, sample_fps: sample_fps}} ->
        # Registered per open, so a crash between here and teardown still
        # frees the decoder — a hardware one holds GPU surfaces.
        Membrane.ResourceGuard.register(
          guard,
          fn -> module.close_decoder(ref) end,
          tag: {:decoder, ref}
        )

        %{
          core
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
        Logger.warning("camera #{core.camera_id}: no native decoder (#{inspect(reason)})")
        reopen_later(core)
    end
  end

  # `cleanup/2` both runs the registered close and unregisters it, so a
  # reopen cannot stack a second guard for a handle that is already gone.
  defp drop_decoder(%{decoder: %{ref: ref}} = core, guard) do
    Membrane.ResourceGuard.cleanup(guard, {:decoder, ref})
    %{core | decoder: :closed, gate: nil}
  end

  defp reopen_later(core) do
    %{core | errors: core.errors + 1, retry_at: now_ms() + core.cooldown_ms}
  end

  # Monotonic milliseconds, which start negative on the BEAM: nothing here may
  # read the value as a sign.
  defp now_ms, do: System.monotonic_time(:millisecond)
end
