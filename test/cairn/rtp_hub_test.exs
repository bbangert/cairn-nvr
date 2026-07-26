defmodule Cairn.RTPHubTest do
  use ExUnit.Case, async: false

  alias Cairn.RTPHub

  defp nal(type, rest \\ <<"x">>), do: <<0::1, 3::2, type::5, rest::binary>>

  defp rtp(seq, ts, payload) do
    payload
    |> ExRTP.Packet.new(payload_type: 96, sequence_number: seq, timestamp: ts, ssrc: 42)
    |> ExRTP.Packet.encode()
  end

  setup do
    camera_id = "hub_#{System.unique_integer([:positive])}"
    port = 20_000 + :rand.uniform(10_000)
    start_supervised!({RTPHub, camera_id: camera_id, port: port})

    {:ok, sender} = :gen_udp.open(0, [:binary])
    on_exit(fn -> :gen_udp.close(sender) end)

    send_packet = fn seq, ts, payload ->
      :ok = :gen_udp.send(sender, {127, 0, 0, 1}, port, rtp(seq, ts, payload))
    end

    %{camera_id: camera_id, send_packet: send_packet}
  end

  test "broadcasts decoded packets on the rtp topic", %{camera_id: id, send_packet: send_packet} do
    Phoenix.PubSub.subscribe(Cairn.PubSub, RTPHub.topic(id))

    send_packet.(1, 1000, nal(1))

    assert_receive {:rtp, %ExRTP.Packet{sequence_number: 1, timestamp: 1000}}, 2_000
  end

  test "gop buffer resets on keyframe boundaries", %{camera_id: id, send_packet: send_packet} do
    Phoenix.PubSub.subscribe(Cairn.PubSub, RTPHub.topic(id))

    # GOP 1: keyframe + two P packets
    send_packet.(1, 1000, nal(7))
    send_packet.(2, 1000, nal(5))
    send_packet.(3, 2000, nal(1))
    assert_receive {:rtp, %{sequence_number: 3}}, 2_000

    assert [1, 2, 3] = RTPHub.gop_snapshot(id) |> Enum.map(& &1.sequence_number)

    # GOP 2 starts: buffer resets to the new keyframe
    send_packet.(4, 3000, nal(7))
    send_packet.(5, 4000, nal(1))
    assert_receive {:rtp, %{sequence_number: 5}}, 2_000

    assert [4, 5] = RTPHub.gop_snapshot(id) |> Enum.map(& &1.sequence_number)
  end

  test "FU-A continuation of the same keyframe does not reset", %{
    camera_id: id,
    send_packet: send_packet
  } do
    Phoenix.PubSub.subscribe(Cairn.PubSub, RTPHub.topic(id))

    # fragmented IDR: same timestamp, start then continuation
    send_packet.(10, 5000, nal(28, <<1::1, 0::1, 0::1, 5::5, "a">>))
    send_packet.(11, 5000, nal(28, <<1::1, 0::1, 0::1, 5::5, "b">>))
    send_packet.(12, 5000, nal(28, <<0::1, 1::1, 0::1, 5::5, "c">>))
    assert_receive {:rtp, %{sequence_number: 12}}, 2_000

    # same-timestamp keyframe fragments must not clear each other
    assert [10, 11, 12] = RTPHub.gop_snapshot(id) |> Enum.map(& &1.sequence_number)
  end

  describe "udp open retry" do
    setup do
      %{
        busy_port: 30_000 + :rand.uniform(10_000),
        busy_id: "retry_#{System.unique_integer([:positive])}"
      }
    end

    test "starts once a lingering predecessor releases the port", ctx do
      test_pid = self()

      {:ok, _holder} =
        Task.start_link(fn ->
          {:ok, socket} = :gen_udp.open(ctx.busy_port, [:binary, ip: {127, 0, 0, 1}])
          send(test_pid, :bound)
          Process.sleep(75)
          :gen_udp.close(socket)
        end)

      assert_receive :bound, 1_000

      pid =
        start_supervised!(
          Supervisor.child_spec({RTPHub, camera_id: ctx.busy_id, port: ctx.busy_port},
            id: :retry_hub
          )
        )

      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "fails with the original error shape once the budget is spent", ctx do
      {:ok, holder} = :gen_udp.open(ctx.busy_port, [:binary, ip: {127, 0, 0, 1}])
      on_exit(fn -> :gen_udp.close(holder) end)

      Process.flag(:trap_exit, true)

      assert {:error, {:udp_open_failed, busy_port, :eaddrinuse}} =
               RTPHub.start_link(camera_id: ctx.busy_id, port: ctx.busy_port, open_attempts: 3)

      assert busy_port == ctx.busy_port
    end
  end

  test "undecodable datagrams are dropped", %{camera_id: id, send_packet: send_packet} do
    Phoenix.PubSub.subscribe(Cairn.PubSub, RTPHub.topic(id))

    {:ok, sender} = :gen_udp.open(0, [:binary])

    hub_port =
      elem(:sys.get_state(Cairn.Registry.whereis(id, :rtp_hub)).socket |> :inet.port(), 1)

    :gen_udp.send(sender, {127, 0, 0, 1}, hub_port, <<1, 2, 3>>)
    :gen_udp.close(sender)

    send_packet.(1, 1000, nal(1))
    assert_receive {:rtp, %{sequence_number: 1}}, 2_000
  end
end
