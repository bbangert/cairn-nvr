// The contract both live players share with CairnWeb.DashboardLive.
//
// `webrtc_active` / `webrtc_inactive` gate the server-rendered detection
// overlay: it draws only while a player says it has a frame on screen. The
// names are lawik's ex_nvr (`good-grid`), where only WebRTC reported; here
// both transports report, but activity alone is not permission to draw —
// DashboardLive.overlay?/3 also requires the :webrtc transport, because
// timestamp-less boxes lead MSE's deliberately delayed playback. MSE's
// reports exist so the gates compose the day a box carries its frame time.
//
// Reports are edge-triggered: `loadeddata` fires again after every source
// reset (an MSE rejoin is several a minute on a flaky camera), and a repeat
// `active` would cost a round trip to tell the LiveView what it already
// knows. Every report carries `camera_id`, which the LiveView checks against
// its own camera list before acting on it.

// The dimensions ride along because the server draws the boxes and cannot
// see the picture: a NormBox is relative to the video FRAME, the overlay's
// percentages resolve against a fixed-aspect TILE, and `object-fit: cover`
// crops the difference away. Only the element knows what that difference is.
// Both callers reach here with a frame decoded, so videoWidth/videoHeight
// are real rather than the 0 they read before metadata.
export function reportActive(hook, video) {
  const width = video.videoWidth
  const height = video.videoHeight
  // A later loadeddata is only a duplicate while the intrinsic dims are
  // unchanged: a source reset can change resolution, and the server corrects
  // box geometry with whatever it was last told.
  if (hook._playerActive && hook._reportedW === width && hook._reportedH === height) return
  hook._playerActive = true
  hook._reportedW = width
  hook._reportedH = height
  hook.pushEvent("webrtc_active", {camera_id: hook.cameraId, width, height})
}

export function reportInactive(hook) {
  if (!hook._playerActive) return
  hook._playerActive = false
  hook.pushEvent("webrtc_inactive", {camera_id: hook.cameraId})
}

// This transport cannot play this camera. The LiveView flips the camera to
// MSE, which re-renders the <video> under a new id and so swaps the hook —
// meaning this hook is on its way out and must not report again.
export function reportTransportFailed(hook) {
  if (hook._transportFailed) return
  hook._transportFailed = true
  reportInactive(hook)
  hook.pushEvent("transport_failed", {camera_id: hook.cameraId})
}

// Wires `loadeddata` — the first decoded frame — to `reportActive`. Fires
// again after any source reset, which is why `reportActive` dedupes.
export function watchFirstFrame(hook, video) {
  hook._onLoadedData = () => reportActive(hook, video)
  video.addEventListener("loadeddata", hook._onLoadedData)
}

// The socket came back and the LiveView remounted, so the server's idea of
// which players are active is empty again — but this hook is still here.
// That combination is the whole problem: a camera on the default transport
// keeps its <video> id across the remount, so morphdom keeps the element
// (`phx-update="ignore"`) and the hook instance survives with its latch
// still set. A stream that never stopped playing will not fire `loadeddata`
// again, so nothing else would ever re-report and the overlay would stay
// dark until the operator toggled transport away and back.
//
// readyState >= 2 is HAVE_CURRENT_DATA: there is a frame on screen right
// now. Below that the mount-time `loadeddata` listener is still armed and
// will report when one arrives.
export function rearmOnReconnect(hook, video) {
  hook._playerActive = false
  if (video.readyState >= 2) reportActive(hook, video)
}

export function unwatchFirstFrame(hook, video) {
  if (hook._onLoadedData) video.removeEventListener("loadeddata", hook._onLoadedData)
  hook._onLoadedData = null
}
