defmodule Cairn.Stage.Step do
  @moduledoc """
  One element of a detect chain: the child `element` is built as, under
  `name`, covering the stages in `covers`.

  `covers` lists several stages for a fused element and none for an adapter
  that only converts between formats. `input` and `output` are format tags,
  compared with `==`:

    * `:h264` — AU-aligned Annex-B H.264 access units, what
      `Cairn.Pipeline.Picker` emits at the head of every chain;
    * `:rgb` — `%Membrane.RawVideo{pixel_format: :RGB}` frames whose metadata
      is `Cairn.Stage.FrameMeta`;
    * `:dma_frame` — frames that stay in a dma-buf (`Cairn.Stage.DmaFrame`);
    * `:detections` — the observations an infer step emits, what every
      chain ends in.
  """

  @enforce_keys [:name, :element, :covers, :input, :output]
  defstruct @enforce_keys

  @type format :: :h264 | :rgb | :dma_frame | :detections | atom()

  @type t :: %__MODULE__{
          name: atom(),
          element: struct() | module(),
          covers: [Cairn.Stage.t()],
          input: format(),
          output: format()
        }
end
