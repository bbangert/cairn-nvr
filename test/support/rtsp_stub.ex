defmodule Cairn.RTSPStub do
  @moduledoc """
  A stand-in for the `rtsp` library's client, for driving
  `Cairn.FFmpegPort`'s `ingest: :rtsp` branch without a camera.

  Mirrors the surface the port calls — `start/1`, `connect/1`, `play/1`,
  `stop/1` — as a real process, so monitors and `:DOWN` semantics hold.
  Each started client announces itself to the test as
  `{:rtsp_started, client, opts}` (the test pid comes from the control
  entry, keyed by the stream uri), and the test then *is* the camera: it
  sends the port `{:rtsp, client, ...}` messages directly, exactly as the
  library's receiver contract delivers them.

  Control map (`:persistent_term`, key `{__MODULE__, uri}`):

    * `test: pid` — where `{:rtsp_started, client, opts}` goes (required)
    * `tracks: [...]` — what `connect/1` answers (default: one H264 video
      track, control path `"video"`, clock rate 90_000)
    * `connect: {:error, reason}` — refuse the connect instead; consumed
      once (the retry after backoff connects normally), so refusal-then-
      recovery is expressible
    * `start: {:error, reason}` — refuse `start/1` itself (no process);
      consumed once, like `connect`
  """

  use GenServer

  def control(uri, attrs) do
    :persistent_term.put({__MODULE__, uri}, attrs)
  end

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

  # -- the surface Cairn.FFmpegPort calls -------------------------------------

  def start(opts) do
    uri = Keyword.fetch!(opts, :stream_uri)
    control = :persistent_term.get({__MODULE__, uri}, %{})

    case control[:start] do
      {:error, _reason} = refusal ->
        :persistent_term.put({__MODULE__, uri}, Map.delete(control, :start))
        if test = control[:test], do: send(test, {:rtsp_start_refused, refusal})
        refusal

      nil ->
        GenServer.start(__MODULE__, opts)
    end
  end

  def connect(client), do: GenServer.call(client, :connect)
  def play(client), do: GenServer.call(client, :play)
  def stop(client), do: GenServer.stop(client)

  # -- GenServer ---------------------------------------------------------------

  @impl true
  def init(opts) do
    uri = Keyword.fetch!(opts, :stream_uri)
    control = :persistent_term.get({__MODULE__, uri}, %{})

    if test = control[:test] do
      send(test, {:rtsp_started, self(), opts})
    end

    {:ok, %{uri: uri, control: control}}
  end

  @impl true
  def handle_call(:connect, _from, state) do
    case state.control[:connect] do
      {:error, _reason} = refusal ->
        # Consumed once: the respawn after backoff finds a healthy camera.
        :persistent_term.put(
          {__MODULE__, state.uri},
          Map.delete(state.control, :connect)
        )

        {:reply, refusal, state}

      nil ->
        {:reply, {:ok, Map.get(state.control, :tracks, default_tracks())}, state}
    end
  end

  def handle_call(:play, _from, state), do: {:reply, :ok, state}
end
