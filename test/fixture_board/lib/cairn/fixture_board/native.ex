defmodule Cairn.FixtureBoard.Native do
  @moduledoc """
  The fixture's NIF library. Only `contract/0` is native; the rest is what a
  library that opens nothing answers. Also the `decoder: fake` library.
  """

  @behaviour Cairn.Stage.EngineNif

  alias Cairn.Stage.EngineNif

  @on_load :load_nif

  # The library comes from this application's `priv`, resolved by name, and
  # its absence fails the load: a directory whose `priv` the node cannot
  # find is refused at attach rather than running without its library.
  @doc false
  def load_nif do
    priv = :code.priv_dir(:cairn_fixture_board)
    :erlang.load_nif(to_charlist(Path.join(priv, "native/libcairn_fixture_board")), 0)
  end

  @impl true
  def available?, do: true

  @impl true
  def load_error, do: nil

  @impl true
  def init(_config), do: {:error, {:unsupported, "the fixture board runs no model"}}

  @impl true
  def engine_spec(_engine), do: raise(ArgumentError, "the fixture board has no engine")

  @impl true
  def open_stream(_engine, _id, _params), do: {:error, {:unsupported, "no engine"}}

  @impl true
  def push_frame(_stream, _payload, _meta, _pts), do: {:error, {:unsupported, "no stream"}}

  @impl true
  def close_stream(_stream), do: {:ok, true}

  @impl true
  def drain_teardown(_timeout_ms), do: true

  @impl true
  def contract, do: :erlang.nif_error(:nif_not_loaded)

  # It decodes no frame, so it takes whatever the base sends.
  @impl true
  def frame_meta_keys, do: EngineNif.frame_meta_keys()

  def open_decoder(_decoder, _params), do: {:error, {:unsupported, "the fixture decodes nothing"}}
  def decode_au(_decoder, _au, _pts, _keyframe?), do: {:error, {:unsupported, "no decoder"}}
  def close_decoder(_decoder), do: {:ok, true}
end
