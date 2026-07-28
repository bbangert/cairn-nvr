# Mock inference plugin — deterministic detection replay for tests/CI.
#
# Honors the plugin contract (docs/plugin-contract.md): config via argv,
# ndjson on stdout, control lines on stdin, logs on stderr. Ignores its UDP
# RTP input entirely; instead it replays a scripted timeline. Both contract
# variants are supported:
#
#   per-camera (one process per camera):
#     elixir mock_plugin.exs --camera-id cam --udp-port 17000 \
#       --min-score-json '{}' --timeline path/to/timeline.json [--loop]
#
#   multiplexed (one process for N cameras):
#     elixir mock_plugin.exs --timeline path/to/timeline.json \
#       --cameras-json '[{"id": "cam", "udp_port": 17000, "min_score": {}}]'
#
# Timeline format (times relative to the first emission):
#
#     [{"at_ms": 100, "pts": 90000,
#       "dets": [{"label": "person", "score": 0.9, "bbox": [0.1,0.1,0.2,0.4]}]}]
#
# An entry may also carry "observed_at" (ISO8601, overriding "now"),
# "time_base" ([num, den]) and per-object "track_id"/"observation_kind".
# In multiplexed mode every timeline entry additionally carries the
# "camera_id" it belongs to, and each emitted line echoes that id.
#
# Two entry keys exist for driving epoch tests deterministically, without the
# test sleeping on a race it cannot observe:
#
#   "await_epoch_change": true — block until the host announces a *different*
#     epoch for this entry's camera before emitting.
#   "epoch": "previous"        — stamp the line with the epoch that most
#     recently ended instead of the current one, i.e. deliberately emit a
#     stale-epoch line the host must drop.
#
# Both are fatal (exit 3, with a stderr line) when what they need never
# arrives: a mock that shrugs and emits something plausible instead turns a
# host-side assertion into one that cannot fail.
#
# Protocol v1 is emitted by default: `plugin.hello`, `plugin.status`, then
# `frame.objects` lines stamped with the `stream_epoch` this plugin was told
# on stdin. `--v0` emits the original `{"pts", "dets"}` shape instead.
# `--object-tracking` declares the `object_tracking` capability, which is what
# makes the host honour per-object "track_id".
{opts, _rest, _invalid} =
  OptionParser.parse(System.argv(),
    strict: [
      camera_id: :string,
      udp_port: :integer,
      min_score_json: :string,
      cameras_json: :string,
      timeline: :string,
      loop: :boolean,
      hold: :boolean,
      v0: :boolean,
      object_tracking: :boolean,
      epoch_wait_ms: :integer
    ]
  )

defmodule MockPlugin do
  @moduledoc false

  @spec emit(map()) :: :ok
  def emit(message), do: IO.puts(JSON.encode!(message))

  @table :mock_plugin_epochs
  @previous :mock_plugin_previous_epochs
  @consumed :mock_plugin_consumed_epochs
  @sequences :mock_plugin_sequences

  @doc "Public tables the stdin reader writes and the emitter reads."
  @spec new_tables() :: :ok
  def new_tables do
    :ets.new(@table, [:named_table, :public, :set])
    :ets.new(@previous, [:named_table, :public, :set])
    :ets.new(@consumed, [:named_table, :public, :set])
    :ets.new(@sequences, [:named_table, :public, :set])
    :ok
  end

  @doc "Sequence numbers are per camera: the host tracks gaps per camera."
  @spec next_sequence(String.t()) :: pos_integer()
  def next_sequence(camera_id), do: :ets.update_counter(@sequences, camera_id, 1, {camera_id, 0})

  @spec epoch(String.t()) :: String.t()
  def epoch(camera_id) do
    case :ets.lookup(@table, camera_id) do
      [{^camera_id, epoch}] -> epoch
      [] -> "unknown"
    end
  end

  @doc """
  The epoch most recently ended for this camera — a stale one, by definition.

  Fatal when there is none. A timeline entry asking for `epoch: "previous"`
  before any stream ended is a test-authoring error, and the fabricated
  `"unknown"` it used to return is refused host-side as `:stale_epoch` too —
  so the test would pass while proving nothing about a real prior epoch.
  """
  @spec previous_epoch(String.t()) :: String.t()
  def previous_epoch(camera_id) do
    case :ets.lookup(@previous, camera_id) do
      [{^camera_id, epoch}] ->
        epoch

      [] ->
        die("no epoch has ended for #{camera_id}: nothing to stamp as `previous`")
    end
  end

  @doc "Loud and fatal: a mock that gives up quietly turns a red test green."
  @spec die(String.t()) :: no_return()
  def die(message) do
    IO.puts(:stderr, "mock plugin: #{message}")
    System.halt(3)
  end

  @doc "Reads control lines forever, recording the epoch of every stream.started."
  @spec read_control() :: :ok
  def read_control do
    case IO.read(:stdio, :line) do
      line when is_binary(line) ->
        record(JSON.decode(line))
        read_control()

      # :eof (stdin closed) or an error: nothing more will ever arrive, but
      # the plugin keeps running on whatever it was already told.
      _done ->
        :ok
    end
  end

  defp record({:ok, %{"type" => "stream.started"} = msg}) do
    with camera_id when is_binary(camera_id) <- msg["camera_id"],
         epoch when is_binary(epoch) <- msg["stream_epoch"] do
      IO.puts(:stderr, "mock plugin: stream.started #{camera_id} #{epoch}")
      :ets.insert(@table, {camera_id, epoch})
    end
  end

  defp record({:ok, %{"type" => "stream.ended"} = msg}) do
    with camera_id when is_binary(camera_id) <- msg["camera_id"] do
      IO.puts(:stderr, "mock plugin: stream.ended #{camera_id} (#{msg["reason"]})")
      remember_previous(camera_id, msg["stream_epoch"])
      :ets.delete(@table, camera_id)
    end
  end

  defp record(_other), do: :ok

  defp remember_previous(camera_id, epoch) when is_binary(epoch),
    do: :ets.insert(@previous, {camera_id, epoch})

  defp remember_previous(_camera_id, _epoch), do: :ok

  @doc """
  Waits until every camera has an epoch.

  Emitting before the host has announced the stream is legal but pointless:
  the epoch would not match and the host would drop the line. The deadline is
  fatal — a plugin that gives up and emits anyway produces lines the host
  refuses for a *second* reason, which is a green test that proved nothing.
  """
  @spec await_epochs([String.t()], integer()) :: :ok
  def await_epochs(camera_ids, wait_ms) do
    # A monotonic deadline computed once: decrementing by the sleep interval
    # drifts optimistically under load, since each turn costs the sleep plus
    # its scheduling.
    poll(
      fn -> Enum.all?(camera_ids, &(epoch(&1) != "unknown")) end,
      deadline(wait_ms),
      10,
      "no stream epoch for #{Enum.join(camera_ids, ", ")} after #{wait_ms}ms"
    )
  end

  @doc """
  Blocks until this camera's stream has been *replaced* — a `stream.ended`
  followed by a `stream.started` — once more than the last satisfied wait for
  this camera.

  Deliberately a state test, not an edge test: "the epoch differs from the one
  I sampled a moment ago" loses the replacement that landed while the emitter
  was still working through earlier entries. Recording which replacement was
  consumed is what keeps a *second* wait in one timeline honest without giving
  that up — the predicate stays level-triggered, it just moves on.
  """
  @spec await_epoch_change(String.t(), integer()) :: :ok
  def await_epoch_change(camera_id, wait_ms) do
    consumed = consumed_change(camera_id)

    poll(
      fn -> changed?(camera_id, consumed) end,
      deadline(wait_ms),
      5,
      "the epoch for #{camera_id} did not change within #{wait_ms}ms"
    )

    :ets.insert(@consumed, {camera_id, previous_epoch(camera_id)})
    :ok
  end

  defp changed?(camera_id, consumed) do
    ended = :ets.lookup(@previous, camera_id)
    ended != [] and ended != [{camera_id, consumed}] and epoch(camera_id) != "unknown"
  end

  defp consumed_change(camera_id) do
    case :ets.lookup(@consumed, camera_id) do
      [{^camera_id, epoch}] -> epoch
      [] -> nil
    end
  end

  defp deadline(wait_ms), do: System.monotonic_time(:millisecond) + wait_ms

  defp poll(predicate, deadline, interval_ms, timed_out) do
    cond do
      predicate.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        die(timed_out)

      true ->
        Process.sleep(interval_ms)
        poll(predicate, deadline, interval_ms, timed_out)
    end
  end
end

cameras =
  case opts[:cameras_json] do
    nil -> nil
    json -> JSON.decode!(json)
  end

camera_id = if cameras, do: nil, else: Keyword.fetch!(opts, :camera_id)
camera_ids = if cameras, do: Enum.map(cameras, & &1["id"]), else: [camera_id]
timeline_path = Keyword.fetch!(opts, :timeline)
v1? = !opts[:v0]
epoch_wait_ms = opts[:epoch_wait_ms] || 3_000

if cameras do
  members = Enum.map_join(cameras, ", ", &"#{&1["id"]}@#{&1["udp_port"]}")
  IO.puts(:stderr, "mock plugin up for #{length(cameras)} cameras: #{members} (udp ignored)")
else
  IO.puts(:stderr, "mock plugin up for #{camera_id}, udp #{opts[:udp_port]} (ignored)")
end

timeline =
  timeline_path
  |> File.read!()
  |> JSON.decode!()

MockPlugin.new_tables()
_reader = spawn_link(&MockPlugin.read_control/0)

if v1? do
  MockPlugin.emit(%{
    "spec" => "cairn.plugin",
    "version" => 1,
    "type" => "plugin.hello",
    "hello" => %{
      "name" => "mock",
      "version" => "1.0.0",
      "supported_versions" => [1],
      "capabilities" => %{"object_tracking" => !!opts[:object_tracking]}
    }
  })

  MockPlugin.emit(%{
    "spec" => "cairn.plugin",
    "version" => 1,
    "type" => "plugin.status",
    "status" => %{"state" => "ready"}
  })

  MockPlugin.await_epochs(camera_ids, epoch_wait_ms)
end

emit = fn entries ->
  started = System.monotonic_time(:millisecond)

  for %{"at_ms" => at_ms, "pts" => pts, "dets" => dets} = entry <- entries do
    delay = at_ms - (System.monotonic_time(:millisecond) - started)
    if delay > 0, do: Process.sleep(delay)
    id = if cameras, do: Map.fetch!(entry, "camera_id"), else: camera_id

    if entry["await_epoch_change"], do: MockPlugin.await_epoch_change(id, epoch_wait_ms)

    if v1? do
      MockPlugin.emit(%{
        "spec" => "cairn.plugin",
        "version" => 1,
        "type" => "frame.objects",
        "camera_id" => id,
        "stream_epoch" =>
          if(entry["epoch"] == "previous",
            do: MockPlugin.previous_epoch(id),
            else: MockPlugin.epoch(id)
          ),
        "sequence" => MockPlugin.next_sequence(id),
        "frame" => %{
          "pts" => pts,
          "time_base" => Map.get(entry, "time_base", [1, 90_000]),
          "observed_at" =>
            Map.get(entry, "observed_at", DateTime.utc_now() |> DateTime.to_iso8601())
        },
        "objects" => dets
      })
    else
      MockPlugin.emit(%{"camera_id" => id, "pts" => pts, "dets" => dets})
    end
  end
end

cond do
  opts[:loop] ->
    Stream.repeatedly(fn -> emit.(timeline) end) |> Stream.run()

  opts[:hold] ->
    # emit once, then stay alive quietly — lets post-window finalization
    # happen without the Port respawning us into a fresh replay
    emit.(timeline)
    Process.sleep(:infinity)

  true ->
    emit.(timeline)
end
