defmodule Cairn.FixtureBoard.FakeDecode do
  @moduledoc "The fixture's decode step: takes access units and emits nothing."

  use Membrane.Filter

  def_input_pad :input, accepted_format: _any
  def_output_pad :output, accepted_format: %Membrane.RawVideo{pixel_format: :RGB}

  @impl true
  def handle_buffer(:input, _buffer, _ctx, state), do: {[], state}
end
