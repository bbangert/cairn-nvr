defmodule Cairn.Native.Status do
  @moduledoc """
  Publishes the native block's health per camera, on the surface a plugin's own
  health already uses: `Cairn.CameraStatus.set_plugin_status/2`, in
  `plugin.status`'s vocabulary (`state`, `detail`, `fps`) plus the native-only
  fields an accelerator has and an external plugin does not.

  A membrane camera has no plugin process reporting for it, so nothing else
  would. It polls rather than being told because the state that matters most has
  no event to be told by: a wedged accelerator stops the sink demanding and
  raises nothing (`Cairn.Native.Health`'s moduledoc).

  `Cairn.Native.Host.status/2` is a call into the process the wedge is inside,
  so it is made under a deadline whose expiry is itself the verdict — the rule
  the monitor probes by. Everything else on a wedged cycle comes from the
  monitor's ETS snapshot, which no call is needed to read.

  Published for every camera *configured* to detect on this node, not only for
  those with an open stream: a canary refusal, an absent NIF or a failed model
  load leaves no stream open at all, and that is exactly when the surface has
  something to say. A classic camera has its own plugin reporting for it and is
  never written here.

  `Cairn.Pipeline.Picker`'s drop counts are *not* on this surface, though a drop
  rate is what saturation looks like from the media side: its `:stats`
  notification is reachable only through the per-session pipeline pid, which
  only `Cairn.FFmpegPort` holds — and that process forwards every chunk of
  ffmpeg's stdout, so asking it would put a status call on the media path.
  `stream_health` and `fps` carry the same evidence from the side that already
  reports without being asked.
  """

  use GenServer

  alias Cairn.CameraStatus
  alias Cairn.Config.Server, as: ConfigServer
  alias Cairn.Native.Health
  alias Cairn.Native.Host

  @interval_ms 5_000
  # The whole cost of a cycle against a wedged host, and the deadline whose expiry
  # is read as the wedge.
  @status_timeout_ms 2_000
  # `plugin.status`'s own bound on `detail`: this surface must not carry a field a
  # plugin's could not.
  @max_detail_bytes 256

  @wedged_detail "A restart is not expected to clear this — NPU state survives kill -9 " <>
                   "(spike 0.5) and every restart above it; the board needs an operator."

  @saturated_detail "The accelerator is retiring work at full rate but cannot keep up: " <>
                      "frames are being shed before the model. Lower sample_fps, or move a " <>
                      "camera off this host."

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Publish now, rather than at the next tick."
  @spec publish(GenServer.server()) :: :ok
  def publish(server \\ __MODULE__), do: GenServer.call(server, :publish)

  @impl true
  def init(opts) do
    state = %{
      host: Keyword.get(opts, :host, Host),
      interval_ms: Keyword.get(opts, :interval_ms, @interval_ms),
      timeout_ms: Keyword.get(opts, :timeout_ms, @status_timeout_ms),
      config_source: Keyword.get(opts, :config_source, &ConfigServer.get/0),
      cameras: []
    }

    schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:publish, _from, state) do
    state = tick(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    schedule(state)
    {:noreply, tick(state)}
  end

  # A reply to a `status/2` that already expired. Discarded rather than matched:
  # its cycle has been reported on, and reporting it again would say the host is
  # answering at a moment nobody asked about.
  def handle_info(_message, state), do: {:noreply, state}

  defp schedule(state), do: Process.send_after(self(), :poll, state.interval_ms)

  defp tick(state) do
    case read(state) do
      # No host is a supervisor's problem, not a camera's: saying anything about
      # the accelerator here would be inventing it.
      :no_subject ->
        state

      status ->
        # Open streams as well as configured cameras: a camera dropped from the
        # config whose stream has not been closed yet is still being detected on.
        cameras = Enum.uniq(configured(state) ++ status.streams)
        Enum.each(cameras, &CameraStatus.set_plugin_status(&1, payload(status, &1)))

        # A camera that has left both sets would otherwise keep the last status
        # it had for the rest of the node's life. `nil` is what a camera nothing
        # has reported for looks like, which is what this one now is.
        Enum.each(state.cameras -- cameras, &CameraStatus.set_plugin_status(&1, nil))

        %{state | cameras: cameras}
    end
  end

  # `plugin:` is what builds the detect branch (`Cairn.FFmpegPort`'s
  # `detect_opts/1`), so it is also what makes this node's engine this camera's
  # detector.
  defp configured(state) do
    state.config_source.().cameras
    |> Enum.filter(&(&1.pipeline == :membrane and &1.plugin != nil))
    |> Enum.map(& &1.id)
  end

  # The verdict is overwritten rather than read from the snapshot on the expiry
  # path: the snapshot is up to a check interval old, and a host that did not
  # answer a deadline is inside a native call *now*. The streams are the last
  # cycle's set, because a host that cannot answer cannot be asked for its own.
  defp read(state) do
    Host.status(state.host, state.timeout_ms)
  catch
    :exit, {:timeout, _call} ->
      state.host
      |> Health.snapshot()
      |> Map.merge(%{
        health: :wedged,
        nif: :unknown,
        engine: :unanswered,
        canary: :unknown,
        model: nil,
        backend: nil,
        streams: state.cameras
      })

    :exit, _down ->
      :no_subject
  end

  # -- the mapping ------------------------------------------------------------

  @doc """
  One camera's slice of `Cairn.Native.Host.status/2`, in `plugin.status`'s shape.

  `state` and `detail` are the headline an operator reads; `health` is the
  verdict itself, which is not recoverable from `state` (a saturated engine and
  an idle one are both working, and neither is a fault). `health` is not a key
  the protocol's status whitelist admits, so one on a stored status can only
  have come from this node — which is what lets a reader branch on it.
  """
  @spec payload(map(), String.t()) :: map()
  def payload(status, camera_id) do
    {state, detail} = headline(status, camera_id)

    %{
      "state" => state,
      "detail" => truncate(detail),
      "fps" => Map.get(status.stream_fps, camera_id, 0.0),
      "health" => term(status.health),
      "stream_health" => term(Map.get(status.stream_health, camera_id, :unknown)),
      "engine" => term(status.engine),
      "nif" => term(status.nif),
      "canary" => term(status.canary),
      "model" => model_name(status.model),
      "backend" => status.backend,
      "p50_ms" => status.p50_ms,
      "cpu_baseline_ms" => status.cpu_baseline_ms,
      "inferences" => status.inferences
    }
  end

  # In the order an operator has to read them: a missing library, then a model
  # the canary refused (whose message is the only account of why nothing is being
  # detected), then any other engine state, and only then this camera's own
  # decoder — the one per-camera failure a node-level story can mask: a refused
  # `decoder:` leaves the engine ready and every other camera detecting, so
  # without this clause the camera reads as a healthy accelerator at 0 fps.
  # The accelerator's verdict comes last.
  defp headline(%{nif: {:unavailable, reason}}, _camera_id) do
    {"error",
     "cairn-native is not loaded (#{inspect(reason)}); no camera on this node is detected on"}
  end

  defp headline(%{canary: {:failed, message}} = status, _camera_id) do
    {"error",
     "the canary refused #{model_name(status.model)}: #{message} — the model was NOT loaded " <>
       "in this VM"}
  end

  defp headline(%{engine: :unanswered}, _camera_id) do
    {"wedged",
     "the engine did not answer a status call, so it is inside a native call that has not " <>
       "returned. " <> @wedged_detail}
  end

  defp headline(%{engine: :starting}, _camera_id),
    do: {"starting", "the engine is still opening its model"}

  defp headline(%{engine: :not_configured}, _camera_id) do
    {"error", "no model is configured for the native engine on this node"}
  end

  defp headline(%{engine: {reason, message}}, _camera_id) do
    {"error", "the engine is #{reason}: #{message}"}
  end

  defp headline(%{engine: :ready} = status, camera_id) do
    # `Map.get`, not a match: the degraded map `unanswered/1` builds carries no
    # decoder_failures key, and this clause must not be the reason a wedged
    # host cannot be reported.
    case status |> Map.get(:decoder_failures, %{}) |> Map.get(camera_id) do
      nil -> accelerator(status)
      reason -> {"error", decoder_failure(reason)}
    end
  end

  defp headline(status, _camera_id), do: {"error", "the engine is #{term(status.engine)}"}

  # The message is the crate's own (which decoder was named, and that `auto` is
  # the escape) — the one account of why this camera detects nothing while the
  # node's engine is healthy. Recording is `Cairn.Native.Host`'s
  # `record_decoder_outcome/3`; the next successful open clears it.
  defp decoder_failure({reason, message}) when is_binary(message) do
    "this camera's decoder did not open (#{reason}): #{message} — detection is off; " <>
      "recording is unaffected"
  end

  defp decoder_failure(reason) do
    "this camera's decoder did not open: #{inspect(reason)} — detection is off; " <>
      "recording is unaffected"
  end

  defp accelerator(%{health: :wedged}) do
    {"wedged",
     "the accelerator has stopped retiring work and detection is silent. " <> @wedged_detail}
  end

  defp accelerator(%{health: :saturated}), do: {"saturated", @saturated_detail}

  defp accelerator(%{health: :idle}) do
    {"idle", "the engine is loaded and no model pass completed in the last check window"}
  end

  defp accelerator(%{health: :not_applicable} = status) do
    {"ready", "detecting on #{status.backend}, which has no accelerator to judge"}
  end

  defp accelerator(%{health: :unknown} = status) do
    {"ready", "detecting on #{status.backend}; too few completed passes to judge it yet"}
  end

  defp accelerator(status), do: {"ready", "detecting on #{status.backend}"}

  # The configured model is a path on this box, and everything here is served
  # through `/api` and the SSE stream, which never emit one (`docs/ha-api.md`).
  # The file's name is what identifies the model to an operator.
  defp model_name(nil), do: nil
  defp model_name(model), do: Path.basename(model)

  # Tuples carry a message `headline/1` has already spent; what is left is the
  # class, which is what a surface groups and filters on.
  defp term(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp term({class, _message}), do: Atom.to_string(class)

  # The bound is in bytes, as the protocol's is; trimming back to the last whole
  # grapheme is what keeps a cut mid-codepoint — a canary message ending in one —
  # out of the JSON encoder this is served through.
  defp truncate(detail) when byte_size(detail) <= @max_detail_bytes, do: detail
  defp truncate(detail), do: whole(binary_part(detail, 0, @max_detail_bytes))

  defp whole(binary) do
    if String.valid?(binary),
      do: binary,
      else: whole(binary_part(binary, 0, byte_size(binary) - 1))
  end
end
