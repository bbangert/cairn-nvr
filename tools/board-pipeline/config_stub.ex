defmodule Cairn.Config do
  @moduledoc """
  Struct-only stand-in for the elixirc slice: `Cairn.Native.Host.reconfigure/2`
  pattern-matches `%Cairn.Config{}`, and an undefined struct in a pattern is a
  compile *error* where an undefined remote call is only a warning. The harness
  never reloads config, so no field is declared. A release or `mix` VM has the
  real module and must never load this file.
  """

  defstruct []
end
