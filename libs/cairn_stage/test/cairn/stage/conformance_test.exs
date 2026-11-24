defmodule Cairn.Stage.ConformanceTest do
  use ExUnit.Case, async: true

  alias Cairn.Stage.Conformance
  alias Cairn.Stage.EngineNif

  # Each callback answers from the test process's dictionary when the test
  # put something there, so one module covers every variant; a function is
  # called, so a callback can raise.
  defp put(key, value), do: Process.put({__MODULE__, key}, value)

  defmodule Element do
    use Membrane.Filter

    def_input_pad :input, accepted_format: _any
    def_output_pad :output, accepted_format: _any
  end

  defmodule Library do
    alias Cairn.Stage.ConformanceTest, as: T

    def available?, do: T.get(:available?, true)
    def load_error, do: nil
    def init(_config), do: {:error, {:fixture, "no model"}}
    def engine_spec(_engine), do: %{}
    def open_stream(_engine, _id, _params), do: {:error, {:fixture, "no stream"}}
    def push_frame(_stream, _payload, _meta, _pts), do: {:error, {:fixture, "no frame"}}
    def close_stream(_stream), do: {:ok, true}
    def drain_teardown(_timeout_ms), do: true
    def contract, do: T.get(:contract, Cairn.Stage.contract())
    def frame_meta_keys, do: T.get(:frame_meta_keys, Cairn.Stage.EngineNif.frame_meta_keys())

    def open_decoder(_decoder, _params), do: {:error, {:fixture, "no decoder"}}
    def decode_au(_decoder, _au, _pts, _key?), do: {:ok, {false, nil}}
    def close_decoder(_decoder), do: {:ok, true}
  end

  defmodule Board do
    @behaviour Cairn.Stage.Board

    alias Cairn.Stage.ConformanceTest, as: T
    alias Cairn.Stage.Step

    @impl true
    def name, do: T.get(:name, "test")

    @impl true
    def detect_chain(%{decoder: "fake"} = context) do
      step = %Step{
        name: :decoder,
        element: T.get(:element, Cairn.Stage.ConformanceTest.Element),
        covers: [:decode, :scale],
        input: :h264,
        output: :rgb
      }

      [step | context.generic]
    end

    def detect_chain(context), do: context.generic

    @impl true
    def decoders, do: ["fake"]

    @impl true
    def backends do
      T.get(:backends, %{
        "fake" => %{
          artifact: "fake",
          fused_nms: true,
          dynamic_shapes: true,
          cpu_twin: false,
          experimental: true,
          conversions: %{evidence: "here", contracts: %{"yolox" => {:unproven, "why"}}}
        }
      })
    end

    @impl true
    def decoder_backend(_decoder), do: T.get(:library, Cairn.Stage.ConformanceTest.Library)

    @impl true
    def engine(_backend),
      do: %{module: T.get(:library, Cairn.Stage.ConformanceTest.Library), canary: "probe"}

    @impl true
    def preflight, do: %{decoders: %{}, backends: %{}}

    @impl true
    def artifacts(_context), do: []

    @impl true
    def profiles_dir, do: T.get(:profiles_dir, nil)
  end

  defmodule Partial do
    def name, do: "partial"
  end

  @doc false
  def get(key, default) do
    case Process.get({__MODULE__, key}, default) do
      fun when is_function(fun, 0) -> fun.()
      value -> value
    end
  end

  defp caps(overrides), do: %{"fake" => Map.merge(Board.backends()["fake"], overrides)}

  test "a conforming board" do
    assert Conformance.check(Board) == :ok
    put(:profiles_dir, System.tmp_dir!())
    assert Conformance.check(Board) == :ok
  end

  test "a module that is not loaded, or does not export every callback" do
    assert {:error, [message]} = Conformance.check(NoSuchBoard)
    assert message =~ "board module NoSuchBoard is not loaded"

    assert {:error, [message]} = Conformance.check(Partial)
    assert message =~ "does not export artifacts/1, backends/0, decoder_backend/1"
  end

  test "capability maps of the wrong shape, each named" do
    put(
      :backends,
      caps(%{
        fused_nms: "yes",
        experimental: "no",
        conversions: %{contracts: %{"yolox" => :maybe}}
      })
    )

    assert {:error, violations} = Conformance.check(Board)
    where = ~s(#{inspect(Board)} backend "fake")

    assert violations == [
             "#{where}: fused_nms is \"yes\"",
             "#{where}: experimental is \"no\"",
             "#{where}: conversions name no evidence",
             "#{where}: conversion \"yolox\" => :maybe is not :proven or {:unproven, reason}"
           ]
  end

  test "a step whose element is not loaded, or is not an element" do
    put(:element, NoSuchElement)
    assert {:error, [message]} = Conformance.check(Board)
    assert message =~ "step :decoder's element NoSuchElement is not loaded"

    put(:element, Partial)
    assert {:error, [message]} = Conformance.check(Board)
    assert message =~ "is not a Membrane element or bin"
  end

  test "an engine library on another contract, naming both numbers" do
    put(:contract, 7)
    assert {:error, [message]} = Conformance.check(Board, contract: 3)

    assert message ==
             "engine library #{inspect(Library)} reports contract 7; this base has contract 3"
  end

  test "a loaded library that predates contract/0 is a mismatch, not a crash" do
    put(:contract, fn -> :erlang.nif_error(:nif_not_loaded) end)
    assert {:error, [message]} = Conformance.check(Board, contract: 3)
    assert message =~ "loaded a library with no contract/0; this base has contract 3"
  end

  test "a contract/0 that fails is named with its raise" do
    put(:contract, fn -> raise "boom" end)
    assert {:error, [message]} = Conformance.check(Board)
    assert message == "engine library #{inspect(Library)}.contract() raised (RuntimeError) boom"
  end

  test "a library that did not load is not asked; a malformed available? is a violation" do
    put(:available?, false)
    put(:contract, fn -> raise "asked" end)
    assert Conformance.check(Board) == :ok

    put(:available?, :maybe)
    assert {:error, [message]} = Conformance.check(Board)
    assert message == "engine library #{inspect(Library)}.available?/0 is :maybe"
  end

  test "a backend or decoder the base requires, missing" do
    requires = %{backends: ["fake", "ort"], decoders: ["auto"]}
    assert {:error, violations} = Conformance.check(Board, requires: requires)

    assert violations == [
             ~s(#{inspect(Board)}.backends/0 offers no "ort"; this base requires that backend of every board),
             ~s(#{inspect(Board)}.decoders/0 offers no "auto"; this base requires that decoder of every board)
           ]

    assert Conformance.check(Board, requires: %{backends: ["fake"], decoders: ["fake"]}) == :ok
  end

  test "an engine decoding other frame metadata keys" do
    {frame, motion} = EngineNif.frame_meta_keys()
    put(:frame_meta_keys, {tl(frame), motion})
    assert {:error, [message]} = Conformance.check(Board)
    assert message =~ "decodes frame metadata keys"
  end

  test "a library that does not export its behaviour" do
    put(:library, Partial)
    assert {:error, violations} = Conformance.check(Board)

    assert Enum.any?(
             violations,
             &(&1 =~ ~s(decoder "fake"'s library) and &1 =~ "close_decoder/1")
           )

    assert Enum.any?(violations, &(&1 =~ ~s(backend "fake"'s engine) and &1 =~ "contract/0"))
  end

  test "a missing profiles directory and a nameless board" do
    put(:profiles_dir, "/no/such/dir")
    put(:name, nil)
    assert {:error, violations} = Conformance.check(Board)

    assert violations == [
             "#{inspect(Board)}.name/0 is nil, not a non-empty string",
             "#{inspect(Board)}.profiles_dir/0 /no/such/dir is no directory"
           ]
  end

  test "a callback that raises is a violation, not a crash" do
    put(:backends, fn -> raise "boom" end)
    assert {:error, [message]} = Conformance.check(Board)
    assert message == "#{inspect(Board)}.backends() raised (RuntimeError) boom"
  end
end
