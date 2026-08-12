defmodule Membrane.MOTTracker.BoundaryTest do
  use ExUnit.Case, async: true

  # The library trees are extraction candidates: they may be lifted into their
  # own hex packages without carrying this application with them. A comment
  # naming the host is as much of a dependency as an alias — it is the thing
  # that stops being true on the day the tree moves — so neither is allowed.
  @trees ["lib/membrane_mot_tracker", "lib/membrane_rtsp_dual_stream"]

  test "no library-tree file names the host application" do
    offenders =
      for tree <- @trees,
          path <- Path.wildcard(Path.join(tree, "**/*.ex")),
          {line, number} <- Enum.with_index(File.stream!(path), 1),
          String.contains?(line, "Cairn."),
          do: "#{path}:#{number}: #{String.trim(line)}"

    assert offenders == []
  end
end
