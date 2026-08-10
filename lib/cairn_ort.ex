defmodule CairnOrt do
  @moduledoc """
  The `cairn-ort` NIF binding: the inference half of the split boundary
  (D-C2). Sampled content-rect RGB frames go in as plain binaries plus
  metadata; observations come out. The model session — onnxruntime CPU or the
  QNN/HTP plugin execution provider, on the library's own in-tree `ort` pin
  (D-C1) — the detection gate, heads/NMS and Re-ID all live behind it.

  Its own namespace rather than `Cairn.*` because the library is shaped for
  extraction (D-C5): nothing in it knows about cameras, policies or this
  application — `Cairn.Native.Host` is one consumer, and
  `Cairn.Pipeline.Inference` can be driven against any provider with the same
  contract.

  The decode half is `Cairn.Native`; the two libraries share no resource. An
  engine's resolved input spec crosses to the decode side as plain terms
  (`engine_spec/1`), spelled by `cairn-detect`'s own wire helpers so the two
  halves cannot be built for different models.

  `config` and `params` must carry every key of the crate's `RawInitConfig` /
  `RawStreamParams`; build them with `Cairn.Native.Config`, never by hand
  (extra keys are ignored by the term decoders, so one normalized config
  serves both libraries).

  A missing library is a normal state, not a boot failure — see
  `Cairn.Native`'s loader notes; this module loads
  `priv/native/libcairn_ort`, overridable via `config :cairn, CairnOrt,
  path: ...`.
  """

  @on_load :load_nif

  @load_result {__MODULE__, :load_result}

  @doc false
  def load_nif do
    :persistent_term.put(@load_result, load())
    :ok
  end

  @doc "True when the NIFs below are the real ones."
  @spec available?() :: boolean()
  def available?, do: load_result() == :ok

  @doc "Why the library did not load, or `nil` when it did."
  @spec load_error() :: term() | nil
  def load_error do
    case load_result() do
      :ok -> nil
      {:error, reason} -> reason
    end
  end

  # `nif_error/1` has no return, so dialyzer flags every *static* call to a stub;
  # `Cairn.Native.Host` calls through a module held in its state, which keeps them
  # dynamic. The nowarn covers the specs, which describe the loaded library.
  @dialyzer {:nowarn_function,
             init: 1,
             engine_spec: 1,
             open_stream: 3,
             push_frame: 4,
             close_stream: 1,
             cpu_baseline_ms: 2}

  @typedoc """
  The engine's resolved input spec as plain terms: what the decode library
  (`Cairn.Native.open_decoder/2`) is built from, since no resource can cross
  between two NIF libraries. The spellings round-trip through `cairn-detect`'s
  own wire helpers.
  """
  @type input_spec :: %{
          width: pos_integer(),
          height: pos_integer(),
          encoding: String.t(),
          resize: String.t(),
          resize_pad: non_neg_integer()
        }

  @typedoc "The motion measurement taken on the decode side, when configured."
  @type motion_verdict :: %{
          changed_fraction: float(),
          motion: boolean(),
          calibrating: boolean(),
          scene_cut: boolean()
        }

  @typedoc "What `push_frame/4` takes alongside the payload binary."
  @type frame_meta :: %{
          width: pos_integer(),
          height: pos_integer(),
          orig_width: pos_integer(),
          orig_height: pos_integer(),
          pts: integer() | nil,
          observed_at_ms: integer(),
          motion: motion_verdict() | nil
        }

  @spec init(map()) :: {:ok, reference()} | {:error, {atom(), String.t()}}
  def init(_config), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  The engine's resolved input spec, for the host to hand to
  `Cairn.Native.open_decoder/2` — one source of truth for what both halves
  are built for.
  """
  @spec engine_spec(reference()) :: input_spec()
  def engine_spec(_engine), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Open one stream on this engine, claiming its stream id: one stream per
  camera, because two would each hold their own gate state while emitting
  under one id.
  """
  @spec open_stream(reference(), String.t(), map()) ::
          {:ok, reference()} | {:error, {atom(), String.t()}}
  def open_stream(_engine, _stream_id, _params), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Take one decoded frame through the detection gate and, when it says so, the
  model. `meta` is `t:frame_meta/0` — the frame map `Cairn.Native.decode_au/4`
  answered with, as `Cairn.Pipeline.Decoder` carries it.
  """
  @spec push_frame(reference(), binary(), frame_meta(), {integer(), integer()}) ::
          {:ok, {[map()], [String.t()]}} | {:error, {atom(), String.t()}}
  def push_frame(_stream, _payload, _meta, _time_base), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  The median cost of `passes` model passes on `config`'s model, on the CPU.

  A second model load on top of `init/1`'s: this opens its own onnxruntime CPU
  session so that the number is the same model's, on this board.
  """
  @spec cpu_baseline_ms(map(), pos_integer()) :: {:ok, float()} | {:error, {atom(), String.t()}}
  def cpu_baseline_ms(_config, _passes), do: :erlang.nif_error(:nif_not_loaded)

  @spec close_stream(reference()) :: {:ok, boolean()} | {:error, {atom(), String.t()}}
  def close_stream(_stream), do: :erlang.nif_error(:nif_not_loaded)

  defp load_result, do: :persistent_term.get(@load_result, {:error, :not_loaded})

  defp load do
    case so_path() do
      {:ok, path} -> :erlang.load_nif(path, 0)
      {:error, _reason} = error -> error
    end
  end

  # No existence check before the load: the BEAM owns the platform's library
  # suffix, so the only reliable way to ask whether the file is there is to try.
  defp so_path do
    case Application.get_env(:cairn, __MODULE__, [])[:path] do
      nil -> priv_path()
      path -> {:ok, String.to_charlist(path)}
    end
  end

  defp priv_path do
    case :code.priv_dir(:cairn) do
      {:error, reason} -> {:error, {:no_priv_dir, reason}}
      dir -> {:ok, :filename.join(dir, ~c"native/libcairn_ort")}
    end
  end
end
