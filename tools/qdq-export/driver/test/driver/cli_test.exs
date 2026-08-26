defmodule Driver.CLITest do
  use ExUnit.Case, async: true

  @campaign_order ~w(push envcheck content latency fetch finish)a

  test "no argument and `all` both mean the full campaign, in order" do
    assert Driver.CLI.parse([]) == {:ok, @campaign_order}
    assert Driver.CLI.parse(["all"]) == {:ok, @campaign_order}
  end

  test "each bash-driver stage name resolves to itself" do
    for stage <- @campaign_order do
      assert Driver.CLI.parse([Atom.to_string(stage)]) == {:ok, [stage]}
    end
  end

  test "unknown or multiple stages are rejected with usage" do
    assert {:error, msg} = Driver.CLI.parse(["bench"])
    assert msg =~ "usage:"
    assert {:error, _} = Driver.CLI.parse(["push", "fetch"])
  end
end
