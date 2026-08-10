defmodule Cairn.Native do
  @moduledoc """
  The `cairn-native` NIF binding, split at the frame (D-C2): `decode_au/4`
  turns compressed access units into content-rect RGB frame maps, and
  `push_frame/4` takes those frames through the motion gate's verdict, the
  model and Re-ID. Every entry point blocks, on a dirty scheduler.

  `config` and `params` must carry every key of the crate's `RawInitConfig` /
  `RawStreamParams`; build them with `Cairn.Native.Config`, never by hand.

  A missing library is a normal state, not a boot failure, so `load_nif/0`
  records why the load failed and still returns `:ok`: an `@on_load` returning
  anything else discards the module, and then every call to it — `available?/0`
  included — raises `undef`.

  The library is looked for at `priv/native/libcairn_native`, overridable via
  `config :cairn, Cairn.Native, path: ...`. Copying the cargo artifact there is
  not wired into `mix compile` yet.
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
             open_stream: 3,
             open_decoder: 3,
             decode_au: 4,
             push_frame: 4,
             close_stream: 1,
             close_decoder: 1,
             cpu_baseline_ms: 2}

  @typedoc """
  One decoded frame on its way across the boundary: `payload` is tightly
  packed RGB24 rows of the *content* rectangle (`width`×`height`), scaled from
  a `orig_width`×`orig_height` source; `pad_w`/`pad_h` are what the model rect
  adds around it (right and bottom), `scale_x`/`scale_y` the per-axis content
  pixels per source pixel. `pts` is the frame's own timestamp in the caller's
  time base, `nil` when the decoder had none to offer.
  """
  @type decoded_frame :: %{
          payload: binary(),
          width: pos_integer(),
          height: pos_integer(),
          orig_width: pos_integer(),
          orig_height: pos_integer(),
          pts: integer() | nil,
          observed_at_ms: integer(),
          scale_x: float(),
          scale_y: float(),
          pad_w: non_neg_integer(),
          pad_h: non_neg_integer(),
          motion: motion_verdict() | nil
        }

  @typedoc "The motion measurement taken on the decode side, when configured."
  @type motion_verdict :: %{
          changed_fraction: float(),
          motion: boolean(),
          calibrating: boolean(),
          scene_cut: boolean()
        }

  @typedoc "`decoded_frame/0` minus what `push_frame/4` takes elsewhere."
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
  The median cost of `passes` model passes on `config`'s model, on the CPU.

  A second model load on top of `init/1`'s: this opens its own onnxruntime CPU
  session so that the number is the same model's, on this board.
  """
  @spec cpu_baseline_ms(map(), pos_integer()) :: {:ok, float()} | {:error, {atom(), String.t()}}
  def cpu_baseline_ms(_config, _passes), do: :erlang.nif_error(:nif_not_loaded)

  @spec open_stream(reference(), String.t(), map()) ::
          {:ok, reference()} | {:error, {atom(), String.t()}}
  def open_stream(_engine, _camera_id, _params), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Open one camera's decoder against the engine's resolved input spec.

  No camera-id claim — that guards the inference stream — and no model: the
  engine is here so both halves of the boundary are built for the same model
  without the host restating it.
  """
  @spec open_decoder(reference(), String.t(), map()) ::
          {:ok, reference()} | {:error, {atom(), String.t()}}
  def open_decoder(_engine, _camera_id, _params), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Feed one access unit; take its frame when `sample` cleared the caller's
  rate gate (`Cairn.Pipeline.SampleGate`).

  The boolean is whether the decoder *completed* a frame for this access unit —
  what the rate gate spends its interval on, whatever became of the
  conversion. Every access unit is decoded regardless of `sample`, because a
  stateful decoder needs its references.
  """
  @spec decode_au(reference(), binary(), integer(), boolean()) ::
          {:ok, {boolean(), decoded_frame() | nil}} | {:error, {atom(), String.t()}}
  def decode_au(_decoder, _au, _pts, _sample), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Take one decoded frame through the detection gate and, when it says so, the
  model. `meta` is `frame_meta/0` — the frame map `decode_au/4` answered with,
  as `Cairn.Pipeline.Decoder` carries it.
  """
  @spec push_frame(reference(), binary(), frame_meta(), {integer(), integer()}) ::
          {:ok, {[map()], [String.t()]}} | {:error, {atom(), String.t()}}
  def push_frame(_stream, _payload, _meta, _time_base), do: :erlang.nif_error(:nif_not_loaded)

  @spec close_stream(reference()) :: {:ok, boolean()} | {:error, {atom(), String.t()}}
  def close_stream(_stream), do: :erlang.nif_error(:nif_not_loaded)

  @spec close_decoder(reference()) :: {:ok, boolean()} | {:error, {atom(), String.t()}}
  def close_decoder(_decoder), do: :erlang.nif_error(:nif_not_loaded)

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
      dir -> {:ok, :filename.join(dir, ~c"native/libcairn_native")}
    end
  end
end
