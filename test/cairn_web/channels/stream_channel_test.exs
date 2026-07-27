defmodule CairnWeb.StreamChannelTest do
  # uses the globally-registered ring for cam_a (from the test config)
  use CairnWeb.ChannelCase, async: false

  alias Cairn.Fragment
  alias Cairn.RingBuffer

  @camera "cam_a"
  @timescale 90_000

  setup do
    start_supervised!({RingBuffer, camera_id: @camera, pre_window_seconds: 60})
    RingBuffer.put_init(@camera, <<"INIT">>, "avc1.64001f", @timescale, Cairn.ULID.generate())
    put_fragment(0)

    {:ok, _, socket} =
      CairnWeb.UserSocket
      |> socket("user", %{})
      |> subscribe_and_join(CairnWeb.StreamChannel, "camera:#{@camera}")

    %{socket: socket}
  end

  defp put_fragment(second) do
    RingBuffer.put_fragment(@camera, %Fragment{
      camera_id: @camera,
      seq: 0,
      pts: second * @timescale,
      duration_ms: 1_000,
      timescale: @timescale,
      data: <<second::32>>
    })
  end

  test "join pushes init and recent fragment as binary frames" do
    assert_push "init", {:binary, <<"INIT">>}
    assert_push "segment", {:binary, <<0::32>>}
  end

  test "live fragments are pushed as they arrive" do
    put_fragment(1)
    assert_push "segment", {:binary, <<1::32>>}
  end

  test "new init segment (ffmpeg respawn) is re-pushed" do
    assert_push "init", {:binary, <<"INIT">>}
    RingBuffer.put_init(@camera, <<"INIT2">>, "avc1.64001f", @timescale, Cairn.ULID.generate())
    assert_push "init", {:binary, <<"INIT2">>}
  end

  test "unknown camera is rejected" do
    assert {:error, %{reason: "unknown camera"}} =
             CairnWeb.UserSocket
             |> socket("user", %{})
             |> subscribe_and_join(CairnWeb.StreamChannel, "camera:nope")
  end

  test "offline camera (no ring) is rejected" do
    assert {:error, %{reason: "camera offline"}} =
             CairnWeb.UserSocket
             |> socket("user", %{})
             |> subscribe_and_join(CairnWeb.StreamChannel, "camera:cam_b")
  end

  test "slow consumer is disconnected", %{socket: socket} do
    Process.unlink(socket.channel_pid)
    Process.monitor(socket.channel_pid)

    # the test process is the transport; an unread mailbox > high-water (8)
    # makes the channel drop us instead of buffering
    Enum.each(1..15, &put_fragment/1)

    assert_receive {:DOWN, _ref, :process, _pid, {:shutdown, :slow_consumer}}, 2_000
  end
end
