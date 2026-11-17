defmodule Cairn.Pipeline.Decoder do
  @moduledoc """
  Decode and resize as their own element: AU-aligned H.264 in, sampled
  content-rect RGB frames out as plain buffers — the seam that makes the
  detection stages composable (D-C2). It is the base's decode step; a board
  with its own decode library may put another in its place
  (`c:Cairn.Stage.Board.detect_chain/1`), behind the same payload convention
  by the time frames reach inference.

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

  `Cairn.Stage.DecoderCore` holds the decoder's lifecycle, the sample gate
  and the output slot, with their rules; this element supplies the input
  geometry, the host and the output buffer. Both pads are `:manual`. The rate
  is the `Cairn.Native.Host.open_decoder/5` reply's `sample_fps`, and because
  the core demands access units at line rate, `Cairn.Pipeline.Picker`
  upstream sheds only when *decode* falls behind the line rate.

  The native decoder opens against `Cairn.Native.Host`'s engine (same model,
  same resolved input spec as the inference stream) and reopens on a
  cooldown after stream-fatal errors, exactly as `Cairn.Pipeline.Inference`
  does for its half.
  """

  use Membrane.Filter

  alias Cairn.Native.Host
  alias Cairn.Stage.DecoderCore
  alias Membrane.Buffer

  @behaviour DecoderCore

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

  @impl true
  def handle_init(_ctx, opts) do
    {[],
     DecoderCore.new(
       camera_id: opts.camera_id,
       element: __MODULE__,
       arg: %{host: opts.host, camera_id: opts.camera_id, params: opts.stream_params},
       cooldown_ms: opts.reopen_cooldown_ms
     )}
  end

  @impl true
  def handle_playing(_ctx, core), do: DecoderCore.playing(core)

  # Swallowed, not forwarded (the filter default would forward it onto the
  # RawVideo pad): the output format is minted in `output/2` from the decoded
  # frame's geometry, which is the model's rect and not the camera's. The
  # geometry is kept, though, for the core's reopen on a change. (Hardware
  # decode itself no longer rides the declared numbers alone: the crate defers
  # its open until the stream's own SPS provides them.)
  @impl true
  def handle_stream_format(:input, %Membrane.H264{} = format, ctx, core),
    do: DecoderCore.stream_format(core, source_of(format), ctx.resource_guard)

  defp source_of(%Membrane.H264{width: w, height: h}) when is_integer(w) and is_integer(h),
    do: {w, h}

  # A parser that declared no geometry leaves the decoder to learn it from the
  # SPS, which is what software decode did for three phases and hardware decode
  # cannot do at all.
  defp source_of(%Membrane.H264{}), do: nil

  # `Cairn.Pipeline.Picker` upstream already refuses an undated buffer; the
  # core refuses it again, since a decode element is meant to stand on its
  # own.
  @impl true
  def handle_buffer(:input, %Buffer{} = buffer, ctx, core) do
    epoch = buffer.metadata[:stream_epoch]
    DecoderCore.buffer(core, buffer.payload, buffer.pts, epoch, ctx.resource_guard)
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, core), do: DecoderCore.demand(core, size)

  @impl true
  def handle_parent_notification(:stats, _ctx, core),
    do: {[notify_parent: {:stats, DecoderCore.stats(core)}], core}

  # A plain `GenServer.call`: the host's liveness is application-supervised
  # (it sits outside every camera's tree), so a missing host is a boot-order
  # fault that should crash this element, not a state to retry around.
  # `Cairn.Native` is named because `output/2` reads its RGB frames' payload.
  @impl DecoderCore
  def open_decoder(arg, source),
    do: Host.open_decoder(arg.host, arg.camera_id, arg.params, source, Cairn.Native)

  # The reason reaches `cameras:status` through the host.
  @impl DecoderCore
  def decoder_refused(arg, message),
    do: Host.report_decoder_refusal(arg.host, arg.camera_id, message)

  @impl DecoderCore
  def output(frame, epoch) do
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
      metadata: Map.put(metadata, :stream_epoch, epoch)
    }

    {format, buffer}
  end
end
