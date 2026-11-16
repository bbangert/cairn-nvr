defmodule Cairn.Stage.DmaFrame do
  @moduledoc """
  The stream format of frames that stay in a dma-buf between elements, rather
  than being copied out as RGB binaries. Defined ahead of any element that
  produces one so that `Cairn.Stage.Step`'s `:dma_frame` and the board
  elements share one name. `owner` is whatever holds the buffers' pool.
  """

  @enforce_keys [:width, :height, :format, :owner]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          width: pos_integer(),
          height: pos_integer(),
          format: atom(),
          owner: term()
        }
end
