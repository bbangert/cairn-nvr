defmodule Cairn.Stage.DmaFrame do
  @moduledoc """
  The stream format of frames that stay in a dma-buf between elements, rather
  than being copied out as RGB binaries: `Cairn.Stage.Step`'s `:dma_frame`.
  `owner` identifies the buffers' pool, so a rebuilt pool is a new format.
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
