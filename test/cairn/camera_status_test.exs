defmodule Cairn.CameraStatusTest do
  use ExUnit.Case, async: false

  alias Cairn.CameraStatus

  setup do
    id = "st_#{System.unique_integer([:positive])}"
    on_exit(fn -> CameraStatus.prune(Map.keys(CameraStatus.all()) -- [id]) end)
    %{id: id}
  end

  test "unknown cameras read as :unknown", %{id: id} do
    assert CameraStatus.get(id) == %{status: :unknown, probe: nil}
  end

  test "set/merge accumulate and broadcast", %{id: id} do
    CameraStatus.subscribe()

    CameraStatus.set(id, :running)
    assert_receive {:camera_status, ^id, %{status: :running}}

    CameraStatus.set_probe(id, %{codec: "h264", fps: 20.0})
    assert_receive {:camera_status, ^id, info}
    assert info.status == :running
    assert info.probe.codec == "h264"

    assert CameraStatus.get(id) == info
    assert CameraStatus.all()[id] == info
  end

  test "prune removes cameras not in the known list", %{id: id} do
    other = "st_other_#{System.unique_integer([:positive])}"
    CameraStatus.set(id, :running)
    CameraStatus.set(other, :running)

    # set/2 is a cast; wait until both writes have landed before snapshotting
    wait_until(fn -> CameraStatus.all()[id] && CameraStatus.all()[other] end)

    keep = Map.keys(CameraStatus.all()) -- [other]
    CameraStatus.prune(keep)

    wait_until(fn -> CameraStatus.all()[other] == nil end)
    assert CameraStatus.all()[id]
  end

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition never became true")

      true ->
        Process.sleep(10)
        wait_until(fun, attempts - 1)
    end
  end
end
