defmodule Membrane.RTSPDualStream.MockRTSP do
  @moduledoc """
  Stand-in for the `rtsp` library's client. Mirrors the surface
  `Membrane.RTSPDualStream.Source` calls — `start/1`, `connect/1`, `play/1`,
  `stop/1` — as a real process, so monitors, `:DOWN` and the "stop/1 leaves
  the GenServer alive" contract all hold. Each started client announces itself
  to the test as `{:rtsp_started, uri, client, opts}` — the uri is what lets a
  dual-stream test wait on one role's session without consuming the other's;
  the test then *is* the camera and sends `{:rtsp, client, ...}` to
  `opts[:receiver]` exactly as the library does.

  `connect:` is a `(attempt_index -> :ok | {:error, reason} | :exit)`
  function, so a whole refusal-then-recovery ladder is one closure.

  In `test/support` rather than beside one test: both the element's own tests
  and the pipeline's dual-stream tests need to be the camera, and the pipeline
  reaches this through `Cairn.Pipeline.Camera`'s `rtsp_module:` seam.
  """

  use GenServer

  def default_tracks do
    [
      %{
        control_path: "video",
        type: :video,
        fmtp: nil,
        rtpmap: %{encoding: "H264", clock_rate: 90_000}
      }
    ]
  end

  def setup(uri, opts) do
    control = %{
      test: self(),
      uri: uri,
      tracks: Keyword.get(opts, :tracks, default_tracks()),
      connect: Keyword.get(opts, :connect, fn _attempt -> :ok end),
      attempts: :counters.new(1, [])
    }

    :persistent_term.put({__MODULE__, uri}, control)
    ExUnit.Callbacks.on_exit(fn -> :persistent_term.erase({__MODULE__, uri}) end)
  end

  def start(opts) do
    control = :persistent_term.get({__MODULE__, Keyword.fetch!(opts, :stream_uri)})
    GenServer.start(__MODULE__, {control, opts})
  end

  def connect(client), do: GenServer.call(client, :connect)
  def play(client), do: GenServer.call(client, :play)

  # Faithful to the library: `stop/1` cleans the session and replies but
  # deliberately leaves the GenServer alive. A stub that died here would
  # mask a client-process leak.
  def stop(client), do: GenServer.call(client, :stop)

  @impl true
  def init({control, opts}) do
    send(control.test, {:rtsp_started, control.uri, self(), opts})
    {:ok, control}
  end

  @impl true
  def handle_call(:connect, _from, control) do
    attempt = :counters.get(control.attempts, 1)
    :counters.add(control.attempts, 1, 1)

    case control.connect.(attempt) do
      :ok ->
        {:reply, {:ok, control.tracks}, control}

      {:error, _reason} = refusal ->
        {:reply, refusal, control}

      # The library's connect/play are GenServer.calls, so a slow camera
      # EXITS the caller rather than returning an error — simulated by
      # stopping without a reply, no real timeout to wait out.
      :exit ->
        {:stop, {:shutdown, :mock_slow_connect}, control}
    end
  end

  def handle_call(:play, _from, control), do: {:reply, :ok, control}
  def handle_call(:stop, _from, control), do: {:reply, :ok, control}
end
