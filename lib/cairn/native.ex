defmodule Cairn.Native do
  @moduledoc """
  The `cairn-native` NIF binding: the decode half of the split boundary
  (D-C2). `decode_au/4` turns compressed access units into content-rect RGB
  frame maps; the inference half — the model, the detection gate, Re-ID — is
  `CairnOrt`, a separate library, and the two share no resource: the input
  spec a decoder is built for arrives in `open_decoder/2`'s params as plain
  terms (`CairnOrt.engine_spec/1` is the producer). Every entry point blocks,
  on a dirty scheduler.

  `params` must carry every key of the crate's `RawDecoderParams`;
  `Cairn.Native.Host.open_decoder/4` builds them, never by hand.

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
  @dialyzer {:nowarn_function, open_decoder: 2, decode_au: 4, close_decoder: 1, drain_teardown: 1}

  @type decoded_frame :: Cairn.Stage.DecoderNif.decoded_frame()
  @type motion_verdict :: Cairn.Stage.FrameMeta.motion_verdict()

  @doc """
  Open one camera's decoder for the input spec an engine resolved.

  `params` carries that spec as plain terms — decoder kind, width/height,
  encoding, resize policy, `motion_json` — exactly as
  `CairnOrt.engine_spec/1` spells it plus the host's own decode config. No
  camera-id claim: that guards the inference stream, in the other library.
  """
  @spec open_decoder(String.t(), map()) ::
          {:ok, reference()} | {:error, {atom(), String.t()}}
  def open_decoder(_camera_id, _params), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Feed one access unit; take its frame when `sample` cleared the caller's
  rate gate (`Cairn.Pipeline.SampleGate`).

  The boolean is whether the decoder *completed* a frame for this access unit —
  what the rate gate spends its interval on, whatever became of the
  conversion. Every access unit is decoded regardless of `sample`, because a
  stateful decoder needs its references.

  `pts` is carried through to the emitted frame untouched, except that a
  decoder opened with `motion_json` reads it as *nanoseconds*
  (`Membrane.Time`): the motion detector's calibration window is elapsed
  frame time.
  """
  @spec decode_au(reference(), binary(), integer(), boolean()) ::
          {:ok, {boolean(), decoded_frame() | nil}} | {:error, {atom(), String.t()}}
  def decode_au(_decoder, _au, _pts, _sample), do: :erlang.nif_error(:nif_not_loaded)

  @spec close_decoder(reference()) :: {:ok, boolean()} | {:error, {atom(), String.t()}}
  def close_decoder(_decoder), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Wait (bounded) for every native drop deferred so far to finish — the exit
  path's call, made before a halt so the VM never races the `cairn-teardown`
  thread mid-drop (`Cairn.Native.Drain` is the caller in the app tree).
  """
  @spec drain_teardown(non_neg_integer()) :: boolean()
  def drain_teardown(_timeout_ms), do: :erlang.nif_error(:nif_not_loaded)

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
