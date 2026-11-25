defmodule Cairn.Rockchip.NativeTest do
  use ExUnit.Case, async: true

  alias Cairn.Rockchip.Native

  # The suite also runs without the library built, so the module has to
  # still be there to say why it did not load.
  test "the module is usable whether or not the library loaded" do
    assert is_boolean(Native.available?())
    assert Native.available?() == (Native.load_error() == nil)

    unless Native.available?() do
      assert {kind, _detail} = Native.load_error()
      assert kind in [:load_failed, :bad_lib, :load, :reload, :upgrade, :old_code]
    end
  end

  unless Native.available?(), do: @tag(skip: "libcairn_rockchip is not built")

  test "the library was built against this stage contract and frame metadata" do
    assert Native.contract() == Cairn.Stage.contract()
    assert Native.frame_meta_keys() == Cairn.Stage.EngineNif.frame_meta_keys()
  end

  # Undeclared (the behaviours conflict), so the compiler checks none of it.
  test "the module exports every decoder callback" do
    Code.ensure_loaded!(Native)

    for {name, arity} <- Cairn.Stage.DecoderNif.behaviour_info(:callbacks),
        do: assert(function_exported?(Native, name, arity), "#{name}/#{arity}")
  end
end
