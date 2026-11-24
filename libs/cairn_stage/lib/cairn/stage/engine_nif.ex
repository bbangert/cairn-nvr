defmodule Cairn.Stage.EngineNif do
  @moduledoc """
  The inference NIF surface the host loads a model and runs streams through.
  A board names its module per `backend:` (`c:Cairn.Stage.Board.engine/1`);
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

  # Authoritative for `t:frame_meta/0`'s keys; `cairn-ort`'s Rust suite reads
  # both lists from this source.
  @frame_meta_keys Enum.sort(~w(width height orig_width orig_height pts observed_at_ms motion)a)
  @motion_keys Enum.sort(~w(changed_fraction motion calibrating scene_cut)a)

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
  # `Cairn.Stage.contract/0` as the library was built.
  @callback contract() :: pos_integer()
  # The keys the library's `push_frame` decodes, as this module's `frame_meta_keys/0` spells them.
  @callback frame_meta_keys() :: {[atom()], [atom()]}

  @doc """
  The keys of `t:frame_meta/0` and of its motion verdict, each sorted. An
  engine NIF's own `frame_meta_keys/0` must equal it: a key the NIF requires
  and the host does not send fails only at the first frame, as an
  `ArgumentError`.
  """
  @spec frame_meta_keys() :: {[atom()], [atom()]}
  def frame_meta_keys, do: {@frame_meta_keys, @motion_keys}
end
