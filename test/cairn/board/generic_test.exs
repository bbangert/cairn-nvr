defmodule Cairn.Board.GenericTest do
  use ExUnit.Case, async: true

  alias Cairn.Board.Generic

  # Stand-ins, so an answer that named the base's modules again would fail.
  @base %{
    decoder: :base_decoder,
    host: :base_host,
    engine: %{module: :base_engine, canary: "base-canary"}
  }

  test "every decoder and backend is answered from the lent base" do
    for decoder <- ["auto", "sw"],
        do: assert(Generic.decoder_backend(decoder, @base) == :base_decoder)

    for backend <- Map.keys(Generic.backends()),
        do: assert(Generic.engine(backend, @base) == @base.engine)
  end
end
