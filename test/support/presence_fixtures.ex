defmodule Cairn.PresenceFixtures do
  @moduledoc """
  The observation shapes the presence lane is fed, shared by the suites that
  drive its three halves — `Cairn.Pipeline.PresenceSinkTest`,
  `Cairn.PresenceRecorderTest` and `Cairn.PresenceRecorderRestoreTest`. One
  copy so a new field on the NIF's object map lands in every suite at once.
  """

  @box [0.1, 0.1, 0.2, 0.4]

  @doc """
  The default bbox — `[x, y, w, h]` normalised, foot at (0.2, 0.5).

  Only cameras without zones use it; every zoned case passes a box named for
  the zone it stands in.
  """
  def box, do: @box

  @doc """
  One model-inferred frame of `Cairn.NativeStub.frame/1`'s shape.

  Dated now rather than at the epoch: the recorder measures every box's offset
  from the frame's own clock against the event's start, so a 1970 stamp would
  put the whole clip a lifetime before event-zero.
  """
  def frame(objects) do
    %{
      Cairn.NativeStub.frame()
      | objects: objects,
        observed_at_ms: DateTime.to_unix(DateTime.utc_now(), :millisecond)
    }
  end

  def object(label, score, kind \\ "detected", bbox \\ @box) do
    %{label: label, score: score, bbox: bbox, track_id: nil, observation_kind: kind}
  end

  @doc """
  Stands in for `Cairn.EventExtractor`: stays alive and hands every cast it is
  sent to the test, which is how the `{:track_boxes, _}` stream is observed.

  Unlinked, so a test that kills it does not take itself down — a monitor on
  the test process is what reaps it instead.
  """
  def relay(test_pid) do
    spawn(fn ->
      Process.monitor(test_pid)
      relay_loop(test_pid)
    end)
  end

  @doc """
  The relay's loop on its own, for a suite that has to spawn the process
  itself — registering it before it starts receiving, say.
  """
  def relay_loop(test_pid) do
    receive do
      {:"$gen_cast", message} ->
        send(test_pid, {:extractor_cast, message})
        relay_loop(test_pid)

      {:DOWN, _ref, :process, ^test_pid, _reason} ->
        :ok

      _other ->
        relay_loop(test_pid)
    end
  end
end
