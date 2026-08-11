defmodule Cairn.Pipeline.DecoderTest do
  # One global control map drives `Cairn.NativeStub`, and the host is named.
  use ExUnit.Case, async: false

  alias Cairn.CanaryStub
  alias Cairn.Native.Host
  alias Cairn.NativeStub
  alias Cairn.Pipeline.Decoder
  alias Membrane.Buffer

  @moduletag :capture_log

  @control NativeStub.control()
  @keyframe <<0, 0, 1, 0x67, 0x42, 0xC0, 0x1F, 0, 0, 1, 0x68, 0xCE, 0x3C, 0, 0, 1, 0x65, 0x88>>

  setup do
    :persistent_term.put(@control, %{test: self()})
    on_exit(fn -> :persistent_term.erase(@control) end)

    {:ok, guard} = Membrane.ResourceGuard.start_link()

    %{
      camera_id: "decode_#{System.unique_integer([:positive])}",
      ctx: %{resource_guard: guard}
    }
  end

  defp control(attrs) do
    :persistent_term.put(@control, Map.merge(:persistent_term.get(@control, %{}), attrs))
  end

  defp start_host(opts \\ []) do
    name = :"decode_host_#{System.unique_integer([:positive])}"

    defaults = [
      name: name,
      native_module: NativeStub,
      ort_module: Cairn.CairnOrtStub,
      canary_module: CanaryStub,
      config: %{model: "m.onnx", backend: "ort"}
    ]

    start_supervised!({Host, Keyword.merge(defaults, opts)}, id: name)
    name
  end

  defp element(ctx, opts \\ []) do
    options =
      struct(
        Decoder,
        Keyword.merge(
          [camera_id: ctx.camera_id, host: ctx.host, reopen_cooldown_ms: 0],
          opts
        )
      )

    {[], state} = Decoder.handle_init(%{}, options)
    state
  end

  defp playing(ctx, state), do: Decoder.handle_playing(ctx.ctx, state)

  # What the H.264 parser sends ahead of the first access unit, and now what
  # opens the decoder: a hardware one needs the source geometry at open.
  defp declare(ctx, state, source \\ {2560, 1920}) do
    {w, h} = source
    format = %Membrane.H264{width: w, height: h, alignment: :au}
    {_actions, state} = Decoder.handle_stream_format(:input, format, ctx.ctx, state)
    state
  end

  defp feed(ctx, state, pts) do
    Decoder.handle_buffer(:input, %Buffer{payload: @keyframe, pts: pts}, ctx.ctx, state)
  end

  defp demand(ctx, state, size \\ 1) do
    Decoder.handle_demand(:output, size, :buffers, ctx.ctx, state)
  end

  describe "the decoder's session" do
    setup ctx, do: Map.put(ctx, :host, start_host())

    test "demands one AU on playing, and opens when the stream format lands", ctx do
      {actions, state} = playing(ctx, element(ctx))

      assert actions == [demand: {:input, 1}]
      # Nothing yet: opening here is what handed a V4L2 M2M decoder a 0x0
      # geometry, which it accepts and then fails every frame on.
      refute_receive {:open_decoder, _camera_id, _params}
      assert state.decoder == :closed

      state = declare(ctx, state)

      camera_id = ctx.camera_id
      assert_receive {:open_decoder, ^camera_id, _params}
      assert %{ref: _, module: NativeStub} = state.decoder
      # the gate's rate is the host's `sample_fps`, not a second config knob
      assert state.gate.interval_ns == div(1_000_000_000, 5)
    end

    test "the scene config reaches the crate: the motion knobs live there", ctx do
      motion = ~s({"enabled":true})

      {_actions, state} = playing(ctx, element(ctx, stream_params: %{motion_json: motion}))
      _state = declare(ctx, state)

      # …alongside the engine's resolved spec, spelled as wire terms, and the
      # source geometry, which is the camera's rather than the model's.
      assert_receive {:open_decoder, _camera_id,
                      %{
                        motion_json: ^motion,
                        encoding: "raw_bgr",
                        width: 4,
                        height: 4,
                        resize: "letterbox",
                        resize_pad: 114,
                        sample_fps: 5,
                        source_width: 2560,
                        source_height: 1920
                      }}
    end

    test "a source that changes geometry gets a new decoder, not a new SPS", ctx do
      {_actions, state} = playing(ctx, element(ctx))
      state = declare(ctx, state)
      assert_receive {:open_decoder, _camera_id, %{source_width: 2560}}
      %{ref: first} = state.decoder

      state = declare(ctx, state, {1280, 720})

      assert_receive {:close_decoder, ^first}
      assert_receive {:open_decoder, _camera_id, %{source_width: 1280, source_height: 720}}
      assert %{ref: _} = state.decoder
      # Immediately, not on the fault cooldown: this is a reconfiguration.
      assert state.retry_at == nil
    end

    test "the same geometry restated does not churn the decoder", ctx do
      {_actions, state} = playing(ctx, element(ctx))
      state = declare(ctx, state)
      assert_receive {:open_decoder, _camera_id, _params}
      # The handler tracked what it opened for — this is what makes the
      # restatement below a real comparison and not an idle callback, and it
      # is the assertion that fails against a handler that ignores formats.
      assert state.source == {2560, 1920}
      %{ref: first} = state.decoder

      state = declare(ctx, state)

      refute_receive {:close_decoder, _ref}
      assert %{ref: ^first} = state.decoder
      assert state.source == {2560, 1920}
    end

    test "a parser that declares no geometry still opens, as software decode needs none",
         ctx do
      {_actions, state} = playing(ctx, element(ctx))
      format = %Membrane.H264{alignment: :au}
      {_actions, state} = Decoder.handle_stream_format(:input, format, ctx.ctx, state)

      # Nothing to reopen for, so the open waits for the first access unit —
      # where it always was for a source whose geometry nobody declared.
      {_actions, state} = feed(ctx, state, 1)

      assert_receive {:open_decoder, _camera_id, %{source_width: nil, source_height: nil}}
      assert %{ref: _} = state.decoder
    end

    test "a refused open costs the AU, not the session", ctx do
      host = start_host(config: nil)
      {actions, state} = playing(ctx, element(%{ctx | host: host}))

      assert actions == [demand: {:input, 1}]
      assert state.decoder == :closed

      # the next AU retries (cooldown 0), and keeps consuming meanwhile
      {actions, state} = feed(ctx, state, 1)
      assert actions == [demand: {:input, 1}]
      assert state.decoder == :closed
    end

    test "a stream-fatal error closes the handle and reopens on the next AU", ctx do
      {_actions, state} = playing(ctx, element(ctx))
      state = declare(ctx, state)
      assert_receive {:open_decoder, _camera_id, _params}

      control(%{decode_au: fn _d, _au, _pts, _s -> {:error, {:panicked, "stage panicked"}} end})
      {actions, state} = feed(ctx, state, 1)

      assert actions == [demand: {:input, 1}]
      assert state.decoder == :closed
      # the guard's cleanup ran the close, so a hardware decoder's surfaces
      # are freed now rather than at the next GC
      assert_receive {:close_decoder, _ref}

      control(%{decode_au: nil})
      {_actions, state} = feed(ctx, state, 2)
      assert %{ref: _} = state.decoder
      assert_receive {:open_decoder, _camera_id, _params}
    end

    test "a decoder that completes nothing at all is called out once", ctx do
      {_actions, state} = playing(ctx, element(ctx))
      state = declare(ctx, state)
      assert_receive {:open_decoder, _camera_id, _params}

      # The shape a V4L2 M2M decoder opened without geometry has: it accepts
      # every access unit and completes no frame, and every one of those is a
      # *tolerated* error, so nothing else in the element would ever say so.
      control(%{decode_au: fn _d, _au, _pts, _s -> {:ok, {false, nil}} end})

      # The send smuggles the final state out of the captured fun; same-process
      # and synchronous, so it is in the mailbox before capture_log returns.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          state = Enum.reduce(1..400, state, fn pts, state -> elem(feed(ctx, state, pts), 1) end)
          send(self(), {:final, state})
        end)

      assert_receive {:final, state}
      assert state.blind?
      assert log =~ "completed no frames in 400 access units"

      # Once per open, not once per access unit.
      log = ExUnit.CaptureLog.capture_log(fn -> feed(ctx, state, 401) end)
      refute log =~ "completed no frames"
    end

    test "a decoder that completes frames is never called blind", ctx do
      {_actions, state} = playing(ctx, element(ctx))
      state = declare(ctx, state)
      assert_receive {:open_decoder, _camera_id, _params}

      state = Enum.reduce(1..400, state, fn pts, state -> elem(feed(ctx, state, pts), 1) end)

      refute state.blind?
      assert state.completed == 400
    end

    test "a fatal-error reopen starts the blind count from zero", ctx do
      {_actions, state} = playing(ctx, element(ctx))
      state = declare(ctx, state)
      assert_receive {:open_decoder, _camera_id, _params}

      # March to the edge of the blind threshold without completing a frame...
      control(%{decode_au: fn _d, _au, _pts, _s -> {:ok, {false, nil}} end})
      state = Enum.reduce(1..399, state, fn pts, state -> elem(feed(ctx, state, pts), 1) end)
      assert state.since_open == 399
      refute state.blind?

      # ...then die and reopen (cooldown 0). A reopen that kept the old count
      # would call the fresh decoder blind on its first quiet access unit.
      control(%{decode_au: fn _d, _au, _pts, _s -> {:error, {:panicked, "stage panicked"}} end})
      {_actions, state} = feed(ctx, state, 400)
      assert state.decoder == :closed

      control(%{decode_au: nil})
      {_actions, state} = feed(ctx, state, 401)
      assert %{ref: _} = state.decoder
      assert state.since_open <= 1
      refute state.blind?
    end

    test "a geometry change bypasses a live cooldown", ctx do
      control(%{
        open_decoder: {:error, {:open_stream, "decoder v4l2 was named but did not open"}}
      })

      {_actions, state} = playing(ctx, element(ctx, reopen_cooldown_ms: 60_000))
      state = declare(ctx, state)

      # The open was refused, so the camera is waiting out a cooldown no
      # access unit will beat...
      assert_receive {:open_decoder, _camera_id, %{source_width: 2560}}
      assert state.decoder == :closed
      assert is_integer(state.retry_at)
      {_actions, state} = feed(ctx, state, 1)
      refute_receive {:open_decoder, _camera_id, _params}

      # ...but a reconfigured camera must not wait out a verdict on its OLD
      # geometry.
      state = declare(ctx, state, {1280, 720})

      assert_receive {:open_decoder, _camera_id, %{source_width: 1280}}
      assert state.decoder == :closed
    end

    test "a parser that starts declaring geometry reopens the SPS-taught decoder", ctx do
      {_actions, state} = playing(ctx, element(ctx))
      format = %Membrane.H264{alignment: :au}
      {_actions, state} = Decoder.handle_stream_format(:input, format, ctx.ctx, state)
      {_actions, state} = feed(ctx, state, 1)
      assert_receive {:open_decoder, _camera_id, %{source_width: nil}}
      %{ref: first} = state.decoder

      # One deliberate churn: the running decoder was healthy, but it was
      # opened for a geometry nobody had confirmed.
      state = declare(ctx, state)

      assert_receive {:close_decoder, ^first}
      assert_receive {:open_decoder, _camera_id, %{source_width: 2560}}
    end

    test "a per-frame error is counted and the session keeps running", ctx do
      {_actions, state} = playing(ctx, element(ctx))

      control(%{decode_au: fn _d, _au, _pts, _s -> {:error, {:decode, "empty access unit"}} end})
      {actions, state} = feed(ctx, state, 1)

      assert actions == [demand: {:input, 1}]
      assert %{ref: _} = state.decoder
      assert state.errors == 1
    end

    test "an access unit with no pts never reaches the NIF", ctx do
      # The NIF's contract is an integer pts; the Picker refuses these
      # upstream, and the element restates the refusal so it stands on its
      # own under any producer.
      {_actions, state} = playing(ctx, element(ctx))

      {actions, state} =
        Decoder.handle_buffer(:input, %Buffer{payload: @keyframe, pts: nil}, ctx.ctx, state)

      assert actions == [demand: {:input, 1}]
      assert state.errors == 1
      refute_receive {:decode_au, _ref, _au, _pts, _sample}
    end
  end

  describe "one access unit" do
    setup ctx, do: Map.put(ctx, :host, start_host())

    test "decodes, and its frame is emitted once demand arrives", ctx do
      {_actions, state} = playing(ctx, element(ctx))
      {actions, state} = feed(ctx, state, 42)

      # no demand yet: the frame waits in the slot
      assert actions == [demand: {:input, 1}]
      assert state.pending != nil

      {actions, state} = demand(ctx, state)
      assert [stream_format: {:output, format}, buffer: {:output, buffer}] = actions
      assert %Membrane.RawVideo{pixel_format: :RGB, width: 2, height: 2, aligned: true} = format
      assert buffer.pts == 42
      assert byte_size(buffer.payload) == 2 * 3 * 2
      assert state.pending == nil
    end

    test "the buffer's metadata carries the letterbox maths and the motion verdict", ctx do
      verdict = %{changed_fraction: 0.25, motion: true, calibrating: false, scene_cut: false}

      control(%{
        decode_au: fn _d, _au, pts, _s ->
          {:ok, {true, NativeStub.decoded_frame(pts: pts, motion: verdict, observed_at_ms: 7)}}
        end
      })

      {_actions, state} = playing(ctx, element(ctx))
      {_actions, state} = feed(ctx, state, 1)
      {[_format, {:buffer, {:output, buffer}}], _state} = demand(ctx, state)

      assert buffer.metadata == %{
               orig_width: 4,
               orig_height: 4,
               scale_x: 0.5,
               scale_y: 0.5,
               pad_w: 2,
               pad_h: 2,
               observed_at_ms: 7,
               motion: verdict
             }
    end

    test "the stream format is re-sent only when the geometry moves", ctx do
      {_actions, state} = playing(ctx, element(ctx))

      {_actions, state} = demand(ctx, state, 3)
      {actions, state} = feed(ctx, state, 1)
      assert [stream_format: _, buffer: _, demand: _] = actions

      # same geometry: no second format. The gate is worked around by hand —
      # what is under test is the emit, not the sampling.
      control(%{
        decode_au: fn _d, _au, pts, _s -> {:ok, {true, NativeStub.decoded_frame(pts: pts)}} end
      })

      {actions, state} = feed(ctx, state, 2)
      assert [buffer: _, demand: _] = actions

      control(%{
        decode_au: fn _d, _au, pts, _s ->
          {:ok,
           {true, NativeStub.decoded_frame(pts: pts, width: 4, payload: :binary.copy(<<0>>, 24))}}
        end
      })

      {actions, _state} = feed(ctx, state, 3)
      assert [stream_format: {:output, %{width: 4}}, buffer: _, demand: _] = actions
    end

    test "a frame nobody demanded is replaced by a newer one, never queued", ctx do
      control(%{
        decode_au: fn _d, _au, pts, _s -> {:ok, {true, NativeStub.decoded_frame(pts: pts)}} end
      })

      {_actions, state} = playing(ctx, element(ctx))
      {_actions, state} = feed(ctx, state, 1)
      {_actions, state} = feed(ctx, state, 2)

      assert state.replaced == 1
      {[_format, {:buffer, {:output, buffer}}], _state} = demand(ctx, state)
      assert buffer.pts == 2
    end
  end

  describe "the rate gate" do
    setup ctx do
      # One frame a second: the second AU of any test lands inside the
      # interval for certain.
      Map.put(ctx, :host, start_host(config: %{model: "m.onnx", backend: "ort", sample_fps: 1}))
    end

    test "decode runs at line rate; only the sample crosses", ctx do
      {_actions, state} = playing(ctx, element(ctx))

      {_actions, state} = feed(ctx, state, 1)
      assert_receive {:decode_au, _ref, _au, 1, true}

      # inside the interval: still decoded — the decoder needs its references —
      # but not sampled
      {_actions, state} = feed(ctx, state, 2)
      assert_receive {:decode_au, _ref, _au, 2, false}
      assert state.sampled == 1
      assert state.pending != nil, "the sampled frame is the first AU's"
    end

    test "a completed frame spends the interval even when nothing crossed", ctx do
      # `{true, nil}`: the frame completed but conversion failed, or the
      # hardware path's graph held it back. The unsplit path set `last_sample`
      # before the conversion, so the split one must too.
      control(%{decode_au: fn _d, _au, _pts, sample -> {:ok, {sample, nil}} end})

      {_actions, state} = playing(ctx, element(ctx))
      {_actions, state} = feed(ctx, state, 1)
      assert_receive {:decode_au, _ref, _au, 1, true}

      {_actions, _state} = feed(ctx, state, 2)
      assert_receive {:decode_au, _ref, _au, 2, false}
    end

    test "an AU that completed nothing leaves the gate open", ctx do
      control(%{decode_au: fn _d, _au, _pts, _sample -> {:ok, {false, nil}} end})

      {_actions, state} = playing(ctx, element(ctx))
      {_actions, state} = feed(ctx, state, 1)
      assert_receive {:decode_au, _ref, _au, 1, true}

      # reordering delay at the head of a stream: the admission was never
      # spent, so the next completed frame samples immediately
      {_actions, _state} = feed(ctx, state, 2)
      assert_receive {:decode_au, _ref, _au, 2, true}
    end
  end
end
