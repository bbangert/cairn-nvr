defmodule Cairn.Stage.EngineNif do
  @moduledoc """
  The inference NIF surface the host loads a model and runs streams through.
  A board names its module per `backend:` (`c:Cairn.Stage.Board.engine/2`);
  errors are `{reason, message}` in the crate's vocabulary.
  """

  alias Cairn.Stage.FrameMeta

  @typedoc """
  The engine's resolved input spec as plain terms: what a decoder is opened
  for, since no resource can cross between two NIF libraries.
  """
  @type input_spec :: %{
          width: pos_integer(),
          height: pos_integer(),
          encoding: String.t(),
          resize: String.t(),
          resize_pad: non_neg_integer()
        }

  @typedoc "What `c:push_frame/4` takes alongside the payload binary."
  @type frame_meta :: %{
          width: pos_integer(),
          height: pos_integer(),
          orig_width: pos_integer(),
          orig_height: pos_integer(),
          pts: integer() | nil,
          observed_at_ms: integer(),
          motion: FrameMeta.motion_verdict() | nil
        }

  @callback available?() :: boolean()
  @callback load_error() :: term() | nil
  @callback init(map()) :: {:ok, reference()} | {:error, {atom(), String.t()}}
  @callback engine_spec(reference()) :: input_spec()
  @callback open_stream(reference(), String.t(), map()) ::
              {:ok, reference()} | {:error, {atom(), String.t()}}
  @callback push_frame(reference(), binary(), frame_meta(), {integer(), integer()}) ::
              {:ok, {[map()], [String.t()]}} | {:error, {atom(), String.t()}}
  @callback close_stream(reference()) :: {:ok, boolean()} | {:error, {atom(), String.t()}}
  # True when every native drop deferred so far finished inside the bound.
  @callback drain_teardown(timeout_ms :: non_neg_integer()) :: boolean()
end
