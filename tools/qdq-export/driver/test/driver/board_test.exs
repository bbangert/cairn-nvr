defmodule Driver.BoardTest do
  use ExUnit.Case, async: true

  @cookie String.duplicate("a1b2", 16)

  # The ssh channel really does emit \r\n — these fixtures keep it.
  test "parse_enable strips CR so the node atom can actually connect" do
    raw =
      ~s({:ok, %{cookie: "#{@cookie}", node: :"vagus@192.168.2.87", ports: 9100..9105}}\r\n)

    assert {:ok, %{node: node, cookie: cookie}} = Driver.Board.parse_enable(raw)
    assert node == :"vagus@192.168.2.87"
    refute Atom.to_string(node) =~ "\r"
    assert cookie == String.to_existing_atom(@cookie)
  end

  test "parse_enable accepts an atom-inspected cookie" do
    raw = ~s({:ok, %{cookie: :"#{@cookie}", node: :"vagus@192.168.2.87"}}\r\n)
    assert {:ok, %{cookie: cookie}} = Driver.Board.parse_enable(raw)
    assert cookie == String.to_existing_atom(@cookie)
  end

  test "parse_enable surfaces the module contract's errors" do
    assert Driver.Board.parse_enable("{:error, :starting}\r\n") == {:error, :starting}
    assert Driver.Board.parse_enable("{:error, :node_gone}\r\n") == {:error, :node_gone}
  end

  test "parse_enable refuses output it cannot pin to the contract shape" do
    assert {:error, {:unparseable_enable, _}} = Driver.Board.parse_enable("Welcome to Nerves\r\n")

    short_cookie = ~s({:ok, %{cookie: "abc123", node: :"vagus@192.168.2.87"}})
    assert {:error, {:unparseable_enable, _}} = Driver.Board.parse_enable(short_cookie)
  end
end
