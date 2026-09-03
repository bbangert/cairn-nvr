defmodule CairnWeb.DashboardLive do
  @moduledoc """
  Camera grid, styled per the Claude Design handoff (docs/design-handoff.md
  round-trip). Functional contracts preserved: tile/status/video ids,
  `data-status`, MsePlayer/WebrtcPlayer hooks, `toggle-transport` events.

  Data contract:

    * `@cameras` — `[%Cairn.Config.Camera{}]` from the active config
    * `@statuses` — `%{camera_id => %{status: atom, probe: map | nil,
      plugin_status: map | nil}}`, live-updated via
      `Cairn.CameraStatus.subscribe/0`
    * `@live_events` — `%{camera_id => true}` from the `"events"` topic
    * `@disk_alert` — from `Cairn.Retention`
    * `@detections` — `%{camera_id => [Cairn.LiveDetections.detection()]}`,
      each broadcast REPLACING that camera's whole list
    * `@active` — `%{camera_id => %{w:, h:} | nil}` for the cameras whose
      player has reported a first frame, the value being that video's
      intrinsic dimensions. The overlay draws for these only, and it is one
      map rather than a set plus a sibling so that "active" and "the frame
      geometry to draw against" cannot go out of step.
  """

  use CairnWeb, :live_view

  alias Cairn.Config
  alias Cairn.LiveDetections
  alias CairnWeb.Components.Vision.Bbox
  alias CairnWeb.EventsLive

  @status_meta %{
    connecting: %{label: "Connecting", color: "var(--hs-warning)", pulse: true},
    running: %{label: "Running", color: "var(--hs-success)"},
    backoff: %{
      label: "Unreachable",
      color: "var(--hs-danger)",
      pulse: true,
      icon: "wifi_off",
      msg: "We can't reach this camera — retrying every 10 s."
    },
    stalled: %{
      label: "Stalled",
      color: "var(--hs-state-on)",
      icon: "motion_photos_paused",
      msg: "The stream stopped sending frames. We're restarting it."
    },
    transcode_unavailable: %{
      label: "Transcode unavailable",
      color: "var(--hs-danger)",
      icon: "sync_problem",
      msg:
        "This stream needs transcoding but the hardware encoder isn't available. " <>
          "Install it or disable transcode for this camera."
    },
    unknown: %{label: "Unknown", color: "var(--hs-fg-3)"}
  }

  # `Cairn.Native.Health`'s verdicts. Distinct on purpose: a wedge is an operator
  # alert a restart is not expected to clear, saturation is load to shed, and
  # idle is idle.
  @health_meta %{
    "healthy" => %{label: "Detecting", color: "var(--hs-success)", icon: "visibility"},
    "not_applicable" => %{label: "Detecting", color: "var(--hs-fg-3)", icon: "visibility"},
    "saturated" => %{label: "Saturated", color: "var(--hs-warning)", icon: "speed"},
    "wedged" => %{label: "Accelerator wedged", color: "var(--hs-danger)", icon: "error"},
    "idle" => %{label: "Idle", color: "var(--hs-fg-3)", icon: "pause_circle"},
    "unknown" => %{label: "Unknown", color: "var(--hs-fg-3)", icon: "help"}
  }

  # The tile's shape, in the two forms that need it: the CSS the template
  # writes and the ratio `cover_correct/2` reconciles boxes against. Derived
  # from one pair of numbers on purpose — they describe the same rectangle,
  # and if they ever disagreed every box on a non-16:9 camera would be wrong
  # by the difference with nothing to show for it.
  @tile_aspect_w 16
  @tile_aspect_h 9
  @tile_aspect @tile_aspect_w / @tile_aspect_h
  @tile_aspect_css "#{@tile_aspect_w} / #{@tile_aspect_h}"

  @impl true
  def mount(_params, _session, socket) do
    cameras = Config.Server.get().cameras

    if connected?(socket) do
      Cairn.CameraStatus.subscribe()
      Cairn.Event.subscribe()
      Cairn.Retention.subscribe()
      Cairn.Config.Server.subscribe()
      # One topic per camera, so a busy camera's frames never wake a socket
      # that is not showing it. The set is fixed only within one mount: a
      # config change re-mounts the whole page (`handle_info/2` below), which
      # re-reads the camera list and re-subscribes these per-camera topics.
      Enum.each(cameras, &LiveDetections.subscribe(&1.id))
    end

    {:ok,
     assign(socket,
       page_title: "Dashboard",
       cameras: cameras,
       statuses: Cairn.CameraStatus.all(),
       live_events: %{},
       transports: %{},
       detections: %{},
       active: %{},
       disk_alert: disk_alert()
     )}
  end

  defp disk_alert do
    Cairn.Retention.alert()
  catch
    :exit, _ -> %{active: false}
  end

  @impl true
  def handle_event("toggle-transport", %{"camera" => camera_id} = params, socket) do
    before = transport(socket.assigns.transports, camera_id)

    socket =
      update(socket, :transports, &set_transport(&1, camera_id, params["transport"]))

    # A REAL switch starts a new player, but the old one's activity report is
    # still in `@active` — the fresh <video> would draw the old detections
    # before its first frame. Only a change clears; re-clicking the selected
    # transport must not blank a healthy overlay.
    if transport(socket.assigns.transports, camera_id) != before do
      {:noreply, deactivate(socket, camera_id)}
    else
      {:noreply, socket}
    end
  end

  # The player hooks' three reports, all keyed by a camera this socket is
  # actually showing — an id from anywhere else is ignored rather than allowed
  # to grow the assigns of a page that would never render it.
  #
  # `webrtc_active`/`webrtc_inactive` gate the overlay: a box drawn over a
  # black rectangle is worse than no box, so nothing draws until the player
  # says it has a frame, and a player that loses one takes its boxes down.
  # Both spellings are lawik's, and both cairn players fire them — the names
  # outlived the WebRTC-only original.
  #
  # `transport_failed` is the WebRTC-to-MSE fallback: signalling or the peer
  # connection failed, and the camera's transport assign flips so the toggle
  # shows what the operator is actually watching. Flipping the assign is also
  # what swaps the hook — the `<video>`'s id carries the transport, so
  # LiveView replaces the element rather than patching it.
  def handle_event(event, %{"camera_id" => camera_id} = params, socket)
      when event in ~w(webrtc_active webrtc_inactive transport_failed) do
    if known_camera?(socket, camera_id) do
      {:noreply, apply_player_report(socket, event, camera_id, params)}
    else
      {:noreply, socket}
    end
  end

  defp apply_player_report(socket, "webrtc_active", camera_id, params) do
    update(socket, :active, &Map.put(&1, camera_id, video_dims(params)))
  end

  defp apply_player_report(socket, "webrtc_inactive", camera_id, _params) do
    deactivate(socket, camera_id)
  end

  defp apply_player_report(socket, "transport_failed", camera_id, _params) do
    update(socket, :transports, &Map.put(&1, camera_id, :mse))
  end

  # The boxes go with the frame they described: a player that comes back
  # would otherwise re-reveal whatever was on screen when it died. Shared by
  # the player's own inactive report and a transport switch, which starts a
  # new player the old report must not vouch for. Dropping the entry drops
  # that player's frame dimensions with it — the reason they live in
  # `@active` rather than beside it.
  defp deactivate(socket, camera_id) do
    socket
    |> update(:active, &Map.delete(&1, camera_id))
    |> update(:detections, &Map.delete(&1, camera_id))
  end

  # The player reads these off `videoWidth`/`videoHeight`, which are real by
  # the time `loadeddata` fires. nil is not an error path to recover from —
  # it is the identity case for `cover_correct/2`, which is what a report
  # arriving without usable dimensions gets.
  defp video_dims(%{"width" => w, "height" => h})
       when is_integer(w) and is_integer(h) and w > 0 and h > 0,
       do: %{w: w, h: h}

  defp video_dims(_params), do: nil

  defp known_camera?(socket, camera_id) do
    Enum.any?(socket.assigns.cameras, &(&1.id == camera_id))
  end

  @impl true
  def handle_info({:camera_status, camera_id, info}, socket) do
    {:noreply, update(socket, :statuses, &Map.put(&1, camera_id, info))}
  end

  def handle_info({kind, %Cairn.Event{} = event}, socket)
      when kind in [:event_started, :event_updated] do
    {:noreply, update(socket, :live_events, &Map.put(&1, event.camera_id, true))}
  end

  def handle_info({:event_ended, %Cairn.Event{} = event}, socket) do
    {:noreply, update(socket, :live_events, &Map.delete(&1, event.camera_id))}
  end

  def handle_info({:disk_alert, alert}, socket) do
    {:noreply, assign(socket, disk_alert: alert)}
  end

  # Replace, never merge: the list is one frame's whole truth, so an empty
  # one is how boxes go away (`Cairn.LiveDetections`). Kept for cameras whose
  # player has not reported in too — gating the write on `active` would make
  # the render that follows `webrtc_active` an empty one, and at a low sample
  # rate that gap is visible.
  def handle_info({:detections, camera_id, detections}, socket) do
    {:noreply, update(socket, :detections, &Map.put(&1, camera_id, detections))}
  end

  # A config change can add, remove or reorder cameras — cheaper to re-mount
  # than to reconcile every assign (`@cameras`, the per-camera detection
  # subscriptions, `@statuses`) against a diff this page does not otherwise
  # need to understand.
  def handle_info({:config_changed, _diff}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/")}
  end

  # The `"events"` topic also carries the per-object track lifecycle, and
  # gains kinds over time; the grid only cares about whether a camera has a
  # live event.
  def handle_info(_msg, socket), do: {:noreply, socket}

  # -- view helpers -----------------------------------------------------------

  defp status(statuses, camera_id) do
    statuses |> Map.get(camera_id, %{}) |> Map.get(:status, :unknown)
  end

  defp meta(status), do: Map.get(@status_meta, status, @status_meta.unknown)

  # WebRTC is the default live view: sub-second latency is what an operator
  # watching a door wants, and the overlay's boxes are only as timely as the
  # frame under them. MSE remains one click away, and a WebRTC player that
  # fails falls back to it on its own (`transport_failed`).
  defp transport(transports, camera_id), do: Map.get(transports, camera_id, :webrtc)

  defp set_transport(transports, camera_id, "mse"), do: Map.put(transports, camera_id, :mse)

  defp set_transport(transports, camera_id, "webrtc"),
    do: Map.put(transports, camera_id, :webrtc)

  # No transport named: flip. The `Map.update/4` default has to be the opposite
  # of `transport/2`'s, or the first bare toggle on an untouched camera is a
  # no-op.
  defp set_transport(transports, camera_id, _bare) do
    Map.update(transports, camera_id, :mse, fn
      :mse -> :webrtc
      :webrtc -> :mse
    end)
  end

  # Two conditions, and the second is a scope boundary rather than taste.
  # v1 draws each box the moment it is broadcast, with no frame time attached
  # to it, so the overlay is only honest over a transport sitting at the live
  # edge. MSE deliberately plays `TARGET_LATENCY_S` (~3 s) back to avoid
  # stall-and-burst, and native HLS further still — over either, the boxes
  # would visibly lead the picture they claim to describe. The player hooks
  # report activity on both transports anyway: the reports are cheap, and
  # this gate composes with them rather than replacing them, so the day a box
  # carries its frame time this condition is all that has to go.
  defp overlay?(active, transports, camera_id) do
    Map.has_key?(active, camera_id) and transport(transports, camera_id) == :webrtc
  end

  # Hardwired: `Bbox.styles/0` enumerates all five for the config key that
  # would render a picker from it, and until that key exists there is no
  # operator surface to choose with.
  defp overlay_style, do: :corner_brackets

  # A function, not `@tile_aspect_css` in the template: inside `~H`, `@name`
  # reads an assign, so the module attribute would be invisible there.
  defp tile_aspect_css, do: @tile_aspect_css

  # Percent geometry off the normalized `[x, y, w, h]`: cairn's boxes are
  # already 0..1, so unlike lawik's grid there are no frame dimensions to
  # divide by and none in the payload — but they are relative to the VIDEO
  # FRAME, and the percentages resolve against the TILE, so `cover_correct/2`
  # has to reconcile the two first (see it). The 0.5–99.5 clamps are lawik's
  # and come last, after correction: they exist to keep a box inside the
  # tile, which is only knowable once it is expressed in the tile's terms.
  # Rounded because the excess digits are sub-pixel and every one of them is
  # LiveView diff bytes at sample rate.
  defp box_style(bbox, dims) do
    [x, y, w, h] = cover_correct(bbox, dims)
    # Intersect with the tile BEFORE the inset clamps: correction can push a
    # box partly or wholly into the cropped-away region, and the origin-only
    # clamp would render a cropped-off box as a sliver pinned to the tile
    # edge instead of removing the cropped span.
    x2 = min(x + w, 1.0)
    y2 = min(y + h, 1.0)
    x = max(x, 0.0)
    y = max(y, 0.0)

    if x2 <= x or y2 <= y do
      "display: none;"
    else
      # Spans measure from the CLAMPED origin: the inset can move left/top by
      # up to 0.5%, and a span still measured from the pre-inset origin would
      # push the far edge past the intersection by the same amount. Clamped
      # unrounded and formatted at the end, so the subtraction does not
      # inherit the display rounding.
      left = clamp(x * 100)
      top = clamp(y * 100)

      "position: absolute; left: #{pct(left)}%; top: #{pct(top)}%; " <>
        "width: #{clamp_span(x2 * 100 - left, left)}%; height: #{clamp_span(y2 * 100 - top, top)}%;"
    end
  end

  # The tile is a fixed 16:9 box and the video inside it is `object-fit:
  # cover` — scaled to fill and centre-cropped on whichever axis has excess.
  # A NormBox describes the WHOLE frame, including the cropped-away part, so
  # over a camera that is not 16:9 (Ben's reolink_main is 4:3) an uncorrected
  # box is offset and mis-scaled on the cropped axis.
  #
  # `f` is the fraction of the frame's cropped axis that survives the crop;
  # `(1 - f) / 2` is what the near edge lost, since cover crops symmetrically.
  # Subtract that, rescale by `f`, and the coordinate is in tile terms. The
  # uncropped axis fills exactly and passes through.
  #
  # Identity when dimensions are unknown, and identity is the RIGHT fallback,
  # not a resignation: it is lawik's own geometry, correct for the 16:9
  # cameras that are most of them. Guessing an aspect would put boxes in the
  # wrong place on cameras that are currently right.
  defp cover_correct(bbox, nil), do: bbox

  defp cover_correct([x, y, w, h], %{w: vw, h: vh}) do
    video_aspect = vw / vh

    if video_aspect < @tile_aspect do
      # narrower than the tile: cover matches widths and crops top and bottom
      f = video_aspect / @tile_aspect
      [x, (y - (1 - f) / 2) / f, w, h / f]
    else
      # wider, or exactly 16:9 — in which case f is 1 and this is identity
      f = @tile_aspect / video_aspect
      [(x - (1 - f) / 2) / f, y, w / f, h]
    end
  end

  defp clamp(percent), do: percent |> min(99.5) |> max(0.5)

  defp clamp_span(percent, offset) do
    percent |> min(99.5 - offset) |> max(0.5 - offset) |> pct()
  end

  defp pct(number), do: Float.round(number / 1, 2)

  # lawik's `detection_summary/1`: what the model sees right now, in words,
  # for an operator who cannot tell a small box from none at tile size.
  defp detection_summary([]), do: "no detections"

  defp detection_summary(detections) do
    detections
    |> Enum.frequencies_by(& &1.label)
    # Busiest label first, ties alphabetical — upstream renders map order,
    # which is deterministic but says nothing. Ordering by count puts what
    # matters at the start of a line the tile may be too narrow to finish.
    |> Enum.sort_by(fn {label, count} -> {-count, label} end)
    |> Enum.map_join(", ", fn
      {label, 1} -> label
      {label, count} -> "#{count} #{label}"
    end)
  end

  defp fmt_score(score), do: :erlang.float_to_binary(score / 1, decimals: 2)

  defp detection(statuses, camera_id) do
    statuses |> Map.get(camera_id, %{}) |> Map.get(:plugin_status)
  end

  # `health` is `Cairn.Native.Status`'s and only ever this node's: the protocol's
  # status whitelist is `state`/`detail`/`fps`, so no plugin line can carry one.
  # A plugin's `state` is a free string the contract forbids branching on, so it
  # is shown verbatim and coloured neutrally.
  # `Cairn.Native.Status`'s `headline/1` derives most states from health —
  # ready, idle, saturated, wedged — where either key tells the same story and
  # health may answer. These are the ones it decides before health is consulted
  # at all, so health must not answer for them: an engine that is refusing or
  # still loading reports `health: :idle` truthfully (nothing is inferring), and
  # an operator reading "Idle" would never learn why. A new headline state has
  # to be classified here or it silently falls through to health.
  @state_outranks_health %{
    "error" => %{label: "Detection failed", color: "var(--hs-danger)", icon: "error"},
    "starting" => %{label: "Starting", color: "var(--hs-fg-3)", icon: "hourglass_empty"}
  }

  defp detection_meta(%{"state" => state} = status)
       when is_map_key(@state_outranks_health, state) do
    @state_outranks_health |> Map.fetch!(state) |> Map.put(:detail, status["detail"])
  end

  defp detection_meta(%{"health" => health} = status) do
    @health_meta
    |> Map.get(health, @health_meta["unknown"])
    |> Map.put(:detail, status["detail"])
  end

  defp detection_meta(%{"state" => state} = status) do
    %{label: state, color: "var(--hs-fg-3)", icon: "sensors", detail: status["detail"]}
  end

  defp detection_meta(_none), do: nil

  attr :camera_id, :string, required: true
  attr :status, :map, default: nil

  defp detection_chip(assigns) do
    assigns = assign(assigns, :meta, detection_meta(assigns.status))

    ~H"""
    <div
      :if={@meta}
      id={"camera-detection-#{@camera_id}"}
      data-health={@status["health"]}
      title={@meta.detail}
      style={"display: inline-flex; align-items: center; gap: 4px; font-size: 11px; font-weight: 600; color: #{@meta.color};"}
    >
      <span class="ms" style="font-size: 14px;">{@meta.icon}</span>
      {@meta.label}
    </div>
    """
  end

  defp summary(cameras, statuses, live_events) do
    total = length(cameras)
    running = Enum.count(cameras, &(status(statuses, &1.id) == :running))
    recording = map_size(live_events)

    base = "#{running} of #{total} running"
    if recording > 0, do: "#{base} · #{recording} recording", else: base
  end

  defp seg_style(true) do
    "border: none; cursor: pointer; padding: 4px 12px; border-radius: 999px; " <>
      "font-size: 11px; font-weight: 600; font-family: var(--hs-font-sans); " <>
      "background: var(--hs-bg-raised); color: var(--hs-fg-1); box-shadow: var(--hs-shadow-xs);"
  end

  defp seg_style(false) do
    "border: none; cursor: pointer; padding: 4px 12px; border-radius: 999px; " <>
      "font-size: 11px; font-weight: 600; font-family: var(--hs-font-sans); " <>
      "background: transparent; color: var(--hs-fg-4);"
  end

  defp tile_style(true) do
    "overflow: hidden; display: flex; flex-direction: column; border-color: var(--hs-red-500); " <>
      "box-shadow: 0 0 0 1px #e5484d, 0 0 18px rgba(229, 72, 77, 0.35);"
  end

  defp tile_style(false), do: "overflow: hidden; display: flex; flex-direction: column;"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page={:dashboard}>
      <aside
        :if={@disk_alert.active}
        id="disk-alert"
        role="alert"
        style="display: flex; align-items: center; gap: 12px; padding: 10px 20px; background: var(--hs-warning-soft); border-bottom: 1px solid var(--hs-border-1); color: var(--hs-warning); flex: none;"
      >
        <span class="ms" style="font-size: 20px; flex: none;">hard_drive</span>
        <div style="font-size: 13px; font-weight: 500; color: var(--hs-fg-1);">
          Low disk space — emergency cleanup is deleting the oldest events.
        </div>
        <div style="flex: 1;"></div>
        <span
          class="tnum"
          style="font-family: var(--hs-font-mono); font-size: 12px; color: var(--hs-warning); font-weight: 500;"
        >
          {@disk_alert[:free_mb]} MB free
        </span>
      </aside>

      <main style="flex: 1; padding: 20px; max-width: 1440px; width: 100%; margin: 0 auto; box-sizing: border-box;">
        <div style="display: flex; align-items: baseline; gap: 12px; margin-bottom: 16px;">
          <h1 style="margin: 0; font-size: 22px; font-weight: 600; letter-spacing: -0.01em; color: var(--hs-fg-1);">
            Cameras
          </h1>
          <span style="font-size: 13px; color: var(--hs-fg-3);">
            {summary(@cameras, @statuses, @live_events)}
          </span>
        </div>

        <div
          :if={@cameras == []}
          id="empty-state"
          style="display: flex; flex-direction: column; align-items: center; gap: 10px; padding: 72px 20px; text-align: center;"
        >
          <span class="ms" style="font-size: 46px; color: var(--hs-fg-4);">videocam</span>
          <div style="font-size: 15px; font-weight: 500; color: var(--hs-fg-1);">
            No cameras yet
          </div>
          <.link id="empty-state-add" navigate={~p"/cameras/new"} class="hs-btn hs-btn--primary">
            Add camera
          </.link>
        </div>

        <section
          id="camera-grid"
          style="display: grid; grid-template-columns: repeat(auto-fill, minmax(340px, 1fr)); gap: 16px;"
        >
          <article
            :for={cam <- @cameras}
            id={"camera-tile-#{cam.id}"}
            class="hs-card"
            style={tile_style(@live_events[cam.id] == true)}
          >
            <div style={"position: relative; aspect-ratio: #{tile_aspect_css()}; background: var(--hs-bg-sunken);"}>
              <video
                id={"camera-video-#{cam.id}-#{transport(@transports, cam.id)}"}
                phx-hook={
                  if transport(@transports, cam.id) == :webrtc, do: "WebrtcPlayer", else: "MsePlayer"
                }
                phx-update="ignore"
                data-camera-id={cam.id}
                data-hls-url={~p"/hls/#{cam.id}/index.m3u8"}
                muted
                autoplay
                playsinline
                style="position: absolute; inset: 0; width: 100%; height: 100%; object-fit: cover;"
              ></video>
              <%!-- Server-rendered, per lawik: the boxes are LiveView diffs
              over the video, not a canvas a hook draws into. `TrackOverlay`
              stays the mechanism for PLAYBACK, where a box has to be found
              for the frame the operator seeked to.

              The wrapper is the TILE, not the picture: the <video> inside it
              is `object-fit: cover`, so a frame that is not the tile's aspect
              is centre-cropped. `box_style/2` reconciles the two from the
              dimensions the player reported, which is why it takes them. --%>
              <div
                :if={overlay?(@active, @transports, cam.id)}
                id={"camera-overlay-#{cam.id}"}
                style="position: absolute; inset: 0; pointer-events: none;"
              >
                <Bbox.bbox
                  :for={det <- Map.get(@detections, cam.id, [])}
                  style_name={overlay_style()}
                  label={det.label}
                  confidence={fmt_score(det.score)}
                  color={EventsLive.track_color(det.label, 0)}
                  style={box_style(det.bbox, Map.get(@active, cam.id))}
                />
              </div>
              <div
                :if={overlay?(@active, @transports, cam.id)}
                id={"camera-detections-#{cam.id}"}
                class="cairn-detection-summary tnum"
              >
                {detection_summary(Map.get(@detections, cam.id, []))}
              </div>
              <div style="position: absolute; top: 10px; left: 10px; display: inline-flex; align-items: center; gap: 6px; padding: 3px 10px 3px 8px; border-radius: 999px; background: rgba(11, 15, 20, 0.78); font-size: 11px; font-weight: 600; letter-spacing: 0.02em; font-family: var(--hs-font-sans);">
                <span
                  id={"camera-status-#{cam.id}"}
                  data-status={status(@statuses, cam.id)}
                  style={"display: inline-flex; align-items: center; gap: 6px; color: #{meta(status(@statuses, cam.id)).color};"}
                >
                  <span style={
                    "width: 7px; height: 7px; border-radius: 50%; background: currentColor;" <>
                      if(meta(status(@statuses, cam.id))[:pulse],
                        do: " animation: cairn-pulse 1.4s ease-in-out infinite;",
                        else: ""
                      )
                  }></span>
                  {meta(status(@statuses, cam.id)).label}
                </span>
              </div>
              <div
                :if={@live_events[cam.id]}
                id={"camera-live-event-#{cam.id}"}
                class="live-event-marker"
                style="position: absolute; top: 10px; right: 10px; display: inline-flex; align-items: center; gap: 6px; padding: 3px 10px; border-radius: 999px; background: var(--hs-red-500); color: white; font-size: 11px; font-weight: 700; letter-spacing: 0.06em; pointer-events: none;"
              >
                <span style="width: 7px; height: 7px; border-radius: 50%; background: white; animation: cairn-rec 1.1s ease-in-out infinite;"></span>
                REC
              </div>
              <div
                :if={meta(status(@statuses, cam.id))[:msg]}
                style="position: absolute; inset: 0; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 8px; background: rgba(11, 15, 20, 0.92); pointer-events: none; padding: 16px; text-align: center;"
              >
                <span
                  class="ms"
                  style={"font-size: 34px; color: #{meta(status(@statuses, cam.id)).color};"}
                >
                  {meta(status(@statuses, cam.id))[:icon]}
                </span>
                <div style="font-size: 13px; color: var(--hs-fg-2); max-width: 260px; line-height: 1.4;">
                  {meta(status(@statuses, cam.id))[:msg]}
                </div>
              </div>
            </div>
            <div style="display: flex; align-items: center; gap: 10px; padding: 10px 12px;">
              <h2 style="margin: 0; font-family: var(--hs-font-mono); font-size: 13px; font-weight: 500;">
                <.link
                  navigate={~p"/cameras/#{cam.id}/edit"}
                  style="color: var(--hs-fg-1); text-decoration: none;"
                >
                  {cam.id}
                </.link>
              </h2>
              <.detection_chip camera_id={cam.id} status={detection(@statuses, cam.id)} />
              <div style="flex: 1;"></div>
              <div
                id={"camera-transport-#{cam.id}"}
                data-transport={transport(@transports, cam.id)}
                style="display: flex; gap: 2px; background: var(--hs-bg-sunken); border-radius: 999px; padding: 2px;"
                title="Stream transport"
              >
                <button
                  phx-click="toggle-transport"
                  phx-value-camera={cam.id}
                  phx-value-transport="mse"
                  style={seg_style(transport(@transports, cam.id) == :mse)}
                >
                  Standard
                </button>
                <button
                  phx-click="toggle-transport"
                  phx-value-camera={cam.id}
                  phx-value-transport="webrtc"
                  style={seg_style(transport(@transports, cam.id) == :webrtc)}
                >
                  Low latency
                </button>
              </div>
            </div>
          </article>
        </section>
      </main>
    </Layouts.app>
    """
  end
end
