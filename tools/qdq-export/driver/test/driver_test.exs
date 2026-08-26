defmodule DriverTest do
  use ExUnit.Case
  doctest Driver

  test "greets the world" do
    assert Driver.hello() == :world
  end
end
