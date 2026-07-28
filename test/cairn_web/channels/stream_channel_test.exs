defmodule CairnWeb.StreamChannelTest do
  # uses the globally-registered ring for cam_a (from the test config)
  #
  # async: false is load-bearing beyond the shared ring: the stale-entry test
  # suspends `Cairn.Registry`'s partition, which the whole application shares.
  use CairnWeb.ChannelCase, async: false

  import Cairn.RegistryHelpers, only: [stale_entry: 2]

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

  # The registry lists the ring for a moment after it dies, so the whereis
  # guard passes and the via-tuple `fetch_recent` exits `:noproc`. The join
  # must still answer "camera offline" instead of crashing the channel.
  test "a stale ring registry entry is reported offline, not a join crash" do
    ring = stale_entry("cam_b", :ring_buffer)
    refute Process.alive?(ring)

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
