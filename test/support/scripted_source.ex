defmodule Cairn.ScriptedSource do
  @moduledoc """
  A `flow_control: :push` source that emits exactly what the test tells it to,
  when it tells it to: every parent notification is a list of Membrane actions
  and is returned verbatim.

  What that buys over a fixed buffer list (`Cairn.PushSource`) is placing a
  buffer *between* two assertions — an element whose behaviour depends on what
  a batch carries has to be driven one batch at a time, with the output of each
  read before the next goes in.
  """

  use Membrane.Source

  def_output_pad(:output, accepted_format: _any, flow_control: :push)

  @impl true
  def handle_init(_ctx, _opts), do: {[], %{}}

  @impl true
  def handle_parent_notification(actions, _ctx, state) when is_list(actions),
    do: {actions, state}
end
