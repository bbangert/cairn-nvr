defmodule Cairn.Stage.DecoderNif do
  @moduledoc """
  The decode NIF surface the host opens and drives decoders through. A board
  names its module per `decoder:` (`c:Cairn.Stage.Board.decoder_backend/1`);
  errors are `{reason, message}` in the crate's vocabulary.
  """

  alias Cairn.Stage.FrameMeta

  @typedoc """
  One decoded frame: the *content* rectangle (`width`×`height`), scaled from
  a `orig_width`×`orig_height` source, either as `payload` — tightly packed
  RGB24 rows — or as a `lease` on the slot of pool `pool` that holds it,
  which the board's own NIF reads out and releases. `pad_w`/`pad_h` are what
  the model rect adds around it (right and bottom), `scale_x`/`scale_y` the
  per-axis content pixels per source pixel. `pts` is the frame's own
  timestamp in the caller's time base, `nil` when the decoder had none to
  offer.
  """
  @type decoded_frame :: rgb_frame() | lease_frame()

  @type rgb_frame :: %{
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
          motion: FrameMeta.motion_verdict() | nil
        }

  @type lease_frame :: %{
          lease: reference(),
          pool: non_neg_integer(),
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
          motion: nil
        }

  @callback available?() :: boolean()
  @callback load_error() :: term() | nil
  @callback open_decoder(String.t(), map()) ::
              {:ok, reference()} | {:error, {atom(), String.t()}}
  @callback decode_au(reference(), binary(), integer(), boolean()) ::
              {:ok, {boolean(), decoded_frame() | nil}} | {:error, {atom(), String.t()}}
  @callback close_decoder(reference()) :: {:ok, boolean()} | {:error, {atom(), String.t()}}
  # True when every native drop deferred so far finished inside the bound.
  @callback drain_teardown(timeout_ms :: non_neg_integer()) :: boolean()
end
