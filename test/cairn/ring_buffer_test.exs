defmodule Cairn.RingBufferTest do
  use ExUnit.Case, async: false

  alias Cairn.Fragment
  alias Cairn.RingBuffer

  @timescale 90_000

  setup do
    camera_id = "ring_#{System.unique_integer([:positive])}"
    start_supervised!({RingBuffer, camera_id: camera_id, pre_window_seconds: 4})
    RingBuffer.put_init(camera_id, <<"INIT">>, "avc1.64001f", @timescale)
    %{camera_id: camera_id}
  end

  defp frag(camera_id, second) do
    %Fragment{
      camera_id: camera_id,
      seq: 0,
      pts: second * @timescale,
      duration_ms: 1_000,
      timescale: @timescale,
      data: <<second::32>>
    }
  end

  defp fill(camera_id, seconds) do
    Enum.each(seconds, &RingBuffer.put_fragment(camera_id, frag(camera_id, &1)))
  end

  test "evicts fragments outside the pre-window", %{camera_id: id} do
    fill(id, 0..9)

    {:ok, %{fragments: frags}} = RingBuffer.fetch_recent(id, 100)
    # 4s window at 1s per fragment: only the newest ~4s survive
    assert length(frags) <= 5
    assert List.last(frags).pts == 9 * @timescale
    assert hd(frags).pts >= 5 * @timescale
  end

  test "re-stamps seq monotonically across init resets", %{camera_id: id} do
    fill(id, 0..2)
    RingBuffer.put_init(id, <<"INIT2">>, "avc1.64001f", @timescale)
    fill(id, 0..1)

    {:ok, %{init: init, fragments: frags}} = RingBuffer.fetch_recent(id, 100)
    assert init == <<"INIT2">>
    # ring cleared on new init; seq continues from previous session
    assert Enum.map(frags, & &1.seq) == [3, 4]
  end

  test "drain_and_subscribe returns buffered fragments and then streams", %{camera_id: id} do
    fill(id, 0..3)

    {:ok, %{init: <<"INIT">>, codec: "avc1.64001f", fragments: drained}} =
      RingBuffer.drain_and_subscribe(id, 2 * @timescale, self())

    assert Enum.map(drained, &div(&1.pts, @timescale)) == [2, 3]

    RingBuffer.put_fragment(id, frag(id, 4))
    assert_receive {:ring_fragment, %Fragment{pts: pts}}
    assert div(pts, @timescale) == 4
  end

  test "no gap or duplicate at the drain boundary", %{camera_id: id} do
    fill(id, 0..3)
    {:ok, %{fragments: drained}} = RingBuffer.drain_and_subscribe(id, nil, self())
    fill(id, 4..6)

    streamed =
      for _ <- 4..6 do
        assert_receive {:ring_fragment, %Fragment{} = f}
        f
      end

    seqs = Enum.map(drained ++ streamed, & &1.seq)
    assert seqs == Enum.to_list(hd(seqs)..(hd(seqs) + length(seqs) - 1))
  end

  test "unsubscribe stops the stream", %{camera_id: id} do
    {:ok, _} = RingBuffer.drain_and_subscribe(id, nil, self())
    RingBuffer.unsubscribe(id, self())
    fill(id, 0..1)
    refute_receive {:ring_fragment, _}, 100
  end

  test "dead subscribers are cleaned up via monitor", %{camera_id: id} do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    {:ok, _} = RingBuffer.drain_and_subscribe(id, nil, pid)
    Process.exit(pid, :kill)

    # give the ring time to process :DOWN, then ensure no crash on fanout
    Process.sleep(50)
    fill(id, 0..1)
    {:ok, %{fragments: frags}} = RingBuffer.fetch_recent(id, 10)
    assert length(frags) == 2
  end

  test "broadcasts fragments and init on PubSub", %{camera_id: id} do
    Phoenix.PubSub.subscribe(Cairn.PubSub, RingBuffer.topic(id))

    RingBuffer.put_init(id, <<"INIT3">>, "avc1.64001f", @timescale)
    assert_receive {:init_segment, %{camera_id: ^id, codec: "avc1.64001f"}}

    RingBuffer.put_fragment(id, frag(id, 0))
    assert_receive {:fragment, %Fragment{}}
  end

  test "last_fragment_at is tracked", %{camera_id: id} do
    assert RingBuffer.last_fragment_at(id) == nil
    fill(id, 0..0)
    assert is_integer(RingBuffer.last_fragment_at(id))
  end
end
