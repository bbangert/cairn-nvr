defmodule Cairn.Stage.DecoderCoreTest do
  # The stubs run in the test process (it is the one calling the core), so
  # their scripted replies live in its process dictionary; only the guard's
  # close runs elsewhere, and the handle is an alias of the test process.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Cairn.Stage.DecoderCore
  alias Membrane.Buffer

  @moduletag :capture_log

  defmodule Nif do
    def decode_au(ref, _payload, pts, sample) do
      send(self(), {:decode_au, ref, pts, sample})

      case Process.get(:decode) do
        nil -> {:ok, {true, if(sample, do: %{pts: pts, width: 4})}}
        fun -> fun.(pts, sample)
      end
    end

    def close_decoder(ref) do
      send(ref, {:closed, ref})
      {:ok, true}
    end
  end

  defmodule Element do
    @behaviour DecoderCore

    @impl true
    def open_decoder(arg, source) do
      send(arg.test, {:open, source})

      case Process.get(:open, :ok) do
        :ok ->
          {:ok, %{ref: Process.alias(), module: Nif, sample_fps: Process.get(:fps, 30)}}

        error ->
          error
      end
    end

    @impl true
    def decoder_refused(arg, message), do: send(arg.test, {:refused, message})

    @impl true
    def output(frame, epoch) do
      format = %Membrane.RawVideo{
        width: frame.width,
        height: 1,
        framerate: nil,
        pixel_format: :RGB,
        aligned: true
      }

      {format, %Buffer{pts: frame.pts, payload: <<>>, metadata: %{epoch: epoch}}}
    end
  end

  defmodule Discarding do
    @behaviour DecoderCore

    @impl true
    defdelegate open_decoder(arg, source), to: Element
    @impl true
    defdelegate decoder_refused(arg, message), to: Element
    @impl true
    defdelegate output(frame, epoch), to: Element
    @impl true
    def discard(arg, frame), do: send(arg.test, {:discarded, frame.pts})
  end

  setup do
    {:ok, guard} = Membrane.ResourceGuard.start_link()
    %{guard: guard}
  end

  defp core(cooldown_ms \\ 0, element \\ Element) do
    {[demand: {:input, 1}], core} =
      DecoderCore.new(
        camera_id: "cam",
        element: element,
        arg: %{test: self()},
        cooldown_ms: cooldown_ms
      )
      |> DecoderCore.playing()

    core
  end

  defp declare(core, guard, source \\ {640, 480}) do
    {[], core} = DecoderCore.stream_format(core, source, guard)
    core
  end

  defp feed(core, guard, pts, epoch \\ nil),
    do: DecoderCore.buffer(core, <<0>>, pts, epoch, guard)

  defp feed!(core, guard, pts) do
    {_actions, core} = feed(core, guard, pts)
    core
  end

  test "opens on the first stream format, ignores a repeat, reopens on a change", %{guard: g} do
    core = declare(core(), g)
    assert_received {:open, {640, 480}}
    %{ref: first} = core.decoder

    assert declare(core, g) == core
    refute_received {:open, _}

    core = declare(core, g, {1280, 720})
    assert_received {:open, {1280, 720}}
    assert_receive {:closed, ^first}
    refute core.decoder.ref == first
  end

  test "a failed open waits out the cooldown; a geometry change clears it", %{guard: g} do
    Process.put(:open, {:error, :loading})
    core = declare(core(60_000), g)
    assert_received {:open, {640, 480}}
    assert core.decoder == :closed and core.errors == 1 and is_integer(core.retry_at)

    Process.put(:open, :ok)
    core = feed!(core, g, 0)
    refute_received {:open, _}
    assert core.errors == 1

    core = declare(core, g, {1280, 720})
    assert_received {:open, {1280, 720}}
    assert %{ref: _} = core.decoder
  end

  test "a stream-fatal error closes and reopens after the cooldown", %{guard: g} do
    core = declare(core(), g)
    assert_received {:open, _}
    %{ref: ref} = core.decoder

    Process.put(:decode, fn _pts, _sample -> {:error, {:poisoned, "bad"}} end)
    {[demand: {:input, 1}], core} = feed(core, g, 0)
    assert core.decoder == :closed and core.errors == 1
    assert is_integer(core.retry_at)
    assert_receive {:closed, ^ref}

    Process.delete(:decode)
    core = feed!(core, g, 1)
    assert_received {:open, {640, 480}}
    assert %{ref: _} = core.decoder
  end

  test "three fatal handles in a row without a frame refuse; :closed never counts", %{guard: g} do
    feed_all = fn core, range, reply ->
      Process.put(:decode, fn _pts, _sample -> {:error, reply} end)
      Enum.reduce(range, core, &feed!(&2, g, &1))
    end

    core = declare(core(), g) |> feed_all.(0..1, {:poisoned, "bad"})
    Process.delete(:decode)
    core = core |> feed!(g, 2) |> feed_all.(3..5, {:closed, "reload"})
    core = feed_all.(core, 6..7, {:poisoned, "bad"})
    assert core.decoder == :closed
    refute_received {:refused, _}

    assert feed_all.(core, 8..8, {:poisoned, "bad"}).decoder == :refused

    assert_received {:refused,
                     "the decoder failed 3 times in a row without a frame (last: poisoned, bad)"}
  end

  test "a refusal goes dark, reports once and waits for a new source", %{guard: g} do
    core = declare(core(), g)
    assert_received {:open, _}
    %{ref: ref} = core.decoder

    Process.put(:decode, fn _pts, _sample -> {:error, {:decoder_refused, "no"}} end)
    core = feed!(core, g, 0)
    assert core.decoder == :refused
    assert_received {:refused, "no"}
    assert_receive {:closed, ^ref}

    core = feed!(core, g, 1)
    refute_received {:open, _}
    refute_received {:refused, _}
    assert DecoderCore.stats(core).decoder == :refused

    Process.delete(:decode)
    core = declare(core, g, {1280, 720})
    assert_received {:open, {1280, 720}}
    assert %{ref: _} = core.decoder
  end

  test "the blind count fires once at 400 AUs and resets on reopen", %{guard: g} do
    Process.put(:decode, fn _pts, _sample -> {:ok, {false, nil}} end)
    core = declare(core(), g)

    {core, log} = with_log(fn -> Enum.reduce(1..399, core, &feed!(&2, g, &1)) end)
    refute log =~ "completed no frames"
    refute core.blind?

    {core, log} = with_log(fn -> Enum.reduce(400..450, core, &feed!(&2, g, &1)) end)
    assert [_one] = Regex.scan(~r/completed no frames in 400 access units/, log)
    assert core.blind? and core.since_open == 450

    core = declare(core, g, {1280, 720})
    assert core.since_open == 0 and core.completed == 0 and not core.blind?
  end

  test "only a sampled completed frame spends the gate", %{guard: g} do
    Process.put(:fps, 1)
    core = declare(core(), g)
    assert core.gate.interval_ns == 1_000_000_000

    Process.put(:decode, fn _pts, _sample -> {:ok, {false, nil}} end)
    core = feed!(core, g, 0)
    assert_received {:decode_au, _, 0, true}
    assert core.sampled == 0

    Process.delete(:decode)
    core = feed!(core, g, 1)
    assert_received {:decode_au, _, 1, true}
    assert core.sampled == 1 and core.completed == 1

    core = feed!(core, g, 2)
    assert_received {:decode_au, _, 2, false}
    assert core.sampled == 1 and core.completed == 2
  end

  test "newest wins, and demand meets a frame in either order", %{guard: g} do
    Process.put(:decode, fn pts, _sample -> {:ok, {true, %{pts: pts, width: 4}}} end)
    core = declare(core(), g)

    # frame first: held, replaced by the next, sent on demand
    {[demand: {:input, 1}], core} = feed(core, g, 0, :a)
    {[demand: {:input, 1}], core} = feed(core, g, 1, :b)
    assert core.replaced == 1 and core.pending.pts == 1

    {[stream_format: {:output, %{width: 4}}, buffer: {:output, buffer}], core} =
      DecoderCore.demand(core, 1)

    assert buffer.pts == 1 and buffer.metadata.epoch == :b
    assert core.pending == nil and core.demand == 0 and core.emitted == 1

    # demand first: the next frame goes out at once, without a repeat format
    {[], core} = DecoderCore.demand(core, 1)
    {[buffer: {:output, %{pts: 2}}, demand: {:input, 1}], core} = feed(core, g, 2)

    # a changed output format is sent again
    Process.put(:decode, fn pts, _sample -> {:ok, {true, %{pts: pts, width: 8}}} end)
    {[], core} = DecoderCore.demand(core, 1)

    assert {[stream_format: {:output, %{width: 8}}, buffer: _, demand: _], core} =
             feed(core, g, 3)

    assert %{emitted: 3, replaced: 1, errors: 0, decoder: :open} =
             DecoderCore.stats(core)
  end

  test "a replaced frame is discarded, an output one is not", %{guard: g} do
    Process.put(:decode, fn pts, _sample -> {:ok, {true, %{pts: pts, width: 4}}} end)
    core = declare(core(0, Discarding), g)
    core = feed!(core, g, 0)
    refute_received {:discarded, _}

    core = feed!(core, g, 1)
    assert_received {:discarded, 0}

    {[_format, buffer: {:output, %{pts: 1}}], _core} = DecoderCore.demand(core, 1)
    refute_received {:discarded, _}
  end

  test "an undated buffer counts an error, decodes nothing and still demands", %{guard: g} do
    core = declare(core(), g)

    assert {[demand: {:input, 1}], core} = feed(core, g, nil)
    refute_received {:decode_au, _, _, _}
    assert DecoderCore.stats(core).errors == 1
  end

  test "a transient decode error keeps the decoder and counts", %{guard: g} do
    core = declare(core(), g)
    Process.put(:decode, fn _pts, _sample -> {:error, {:decode_failed, "x"}} end)

    {actions, core} = feed(core, g, 0)

    assert %{ref: _} = core.decoder
    assert core.errors == 1 and core.since_open == 1 and core.completed == 0
    refute_receive {:closed, _}, 50
    assert actions == [demand: {:input, 1}]
  end

  test "stats before any stream format say closed" do
    assert DecoderCore.stats(core()) ==
             %{sampled: 0, emitted: 0, replaced: 0, errors: 0, decoder: :closed}
  end

  test "a nil source opens, and learning the geometry reopens", %{guard: g} do
    core = feed!(core(), g, 0)
    assert_received {:open, nil}
    %{ref: first} = core.decoder

    core = declare(core, g, {640, 480})
    assert_received {:open, {640, 480}}
    assert_receive {:closed, ^first}
    refute core.decoder.ref == first
  end

  test "a decoder that has completed a frame is never called blind", %{guard: g} do
    core = feed!(declare(core(), g), g, 0)
    assert core.completed == 1

    Process.put(:decode, fn _pts, _sample -> {:ok, {false, nil}} end)
    {core, log} = with_log(fn -> Enum.reduce(1..450, core, &feed!(&2, g, &1)) end)

    refute log =~ "completed no frames"
    refute core.blind?
  end
end
