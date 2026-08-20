// MSE live player hook.
//
// Speaks the `camera:{id}` Phoenix channel: join reply carries the RFC 6381
// codec string, then the server pushes binary "init" / "segment" frames.
// Appends into a MediaSource SourceBuffer, trims history beyond 30s, and
// rejoins with backoff whenever the channel closes (including the server's
// :slow_consumer disconnect — reconnecting lands us back at the live edge).
// Falls back to native HLS (<video src>) when MediaSource is unavailable.
import {Socket} from "phoenix"
import {
  rearmOnReconnect,
  reportInactive,
  unwatchFirstFrame,
  watchFirstFrame,
} from "./player_activity"

const BUFFER_KEEP_SECONDS = 30
// Fragments arrive in ~2s chunks; playing closer to the edge than one
// fragment guarantees stall-and-burst playback. Sit ~1.5 fragments back
// and only jump when we've fallen genuinely behind.
const TARGET_LATENCY_S = 3.0
const MAX_DRIFT_S = 8.0
const REJOIN_MIN_MS = 1000
const REJOIN_MAX_MS = 10000

let sharedSocket = null

function socket() {
  if (!sharedSocket) {
    sharedSocket = new Socket("/socket")
    sharedSocket.connect()
  }
  return sharedSocket
}

const MsePlayer = {
  mounted() {
    this.cameraId = this.el.dataset.cameraId
    this.hlsUrl = this.el.dataset.hlsUrl
    this.queue = []
    this.rejoinMs = REJOIN_MIN_MS
    // NB: not `this.destroyed` — that is the LiveView lifecycle callback name,
    // and assigning it replaces the method with a boolean, so teardown never
    // runs and the rejoin loop below outlives the element.
    this.stopped = false
    this.rejoinTimer = null
    watchFirstFrame(this, this.el)

    if (!("MediaSource" in window)) {
      // Safari/iOS: native HLS playback
      this.el.src = this.hlsUrl
      return
    }
    this.join()
  },

  // Reached when the LiveView itself crashed and remounted: this hook's own
  // socket and SourceBuffer are untouched and still filling, so the picture
  // never went away — only the server's record of it did.
  reconnected() {
    rearmOnReconnect(this, this.el)
  },

  destroyed() {
    this.stopped = true
    unwatchFirstFrame(this, this.el)
    reportInactive(this)
    this.leave()
  },

  join() {
    if (this.stopped) return
    this.channel = socket().channel(`camera:${this.cameraId}`)

    this.channel.on("init", payload => this.onInit(payload))
    this.channel.on("segment", payload => this.enqueue(payload))
    this.channel.onClose(() => this.scheduleRejoin())
    this.channel.onError(() => this.channel.leave())

    this.channel.join()
      .receive("ok", ({codec}) => this.setupMediaSource(codec))
      .receive("error", () => this.scheduleRejoin())
  },

  leave() {
    if (this.rejoinTimer) {
      clearTimeout(this.rejoinTimer)
      this.rejoinTimer = null
    }
    if (this.channel) {
      this.channel.onClose(() => {})
      this.channel.leave()
      this.channel = null
    }
    this.teardownMediaSource()
  },

  scheduleRejoin() {
    // Re-entrant: onClose (incl. onError -> leave) and a join error reply can
    // both fire for one disconnect. Bail if a rejoin is already pending so we
    // never leak a timer and race two join()s (the churn this hook fixes).
    if (this.stopped || this.rejoinTimer) return
    // The picture is going away, so the overlay's boxes must too. No
    // `transport_failed` counterpart here: MSE is where WebRTC falls back
    // to, and this hook retries rather than giving up.
    reportInactive(this)
    this.teardownMediaSource()
    const delay = this.rejoinMs
    this.rejoinMs = Math.min(this.rejoinMs * 2, REJOIN_MAX_MS)
    this.rejoinTimer = setTimeout(() => {
      this.rejoinTimer = null
      if (this.stopped) return
      if (this.channel) { this.channel.leave(); this.channel = null }
      this.join()
    }, delay)
  },

  setupMediaSource(codec) {
    this.teardownMediaSource()
    this.mimeType = `video/mp4; codecs="${codec}"`
    if (!MediaSource.isTypeSupported(this.mimeType)) {
      this.el.src = this.hlsUrl
      return
    }
    this.mediaSource = new MediaSource()
    this.el.src = URL.createObjectURL(this.mediaSource)
    this.mediaSource.addEventListener("sourceopen", () => {
      if (!this.mediaSource || this.sourceBuffer) return
      this.sourceBuffer = this.mediaSource.addSourceBuffer(this.mimeType)
      this.sourceBuffer.addEventListener("updateend", () => this.appendNext())
      this.appendNext()
    }, {once: true})
  },

  teardownMediaSource() {
    this.queue = []
    this.sourceBuffer = null
    if (this.mediaSource) {
      try { URL.revokeObjectURL(this.el.src) } catch (_e) { /* noop */ }
      this.mediaSource = null
    }
    this.el.removeAttribute("src")
  },

  onInit(payload) {
    // A fresh init mid-stream means ffmpeg restarted: reset the pipeline.
    if (this.sourceBuffer) {
      this.queue = []
      this.pendingInit = payload
      this.setupMediaSourceFromPending()
    } else {
      this.enqueue(payload)
    }
  },

  setupMediaSourceFromPending() {
    const init = this.pendingInit
    this.pendingInit = null
    this.setupMediaSource(this.mimeType.match(/codecs="(.+)"/)[1])
    this.enqueue(init)
  },

  enqueue(payload) {
    this.queue.push(new Uint8Array(payload))
    this.appendNext()
  },

  appendNext() {
    if (!this.sourceBuffer || this.sourceBuffer.updating) return
    if (this.trimBuffer()) return
    this.nudgeToLiveEdge()
    const chunk = this.queue.shift()
    if (!chunk) return
    this.rejoinMs = REJOIN_MIN_MS
    try {
      this.sourceBuffer.appendBuffer(chunk)
    } catch (_e) {
      // QuotaExceeded or detached buffer: reconnect fresh at the live edge
      this.scheduleRejoin()
    }
  },

  trimBuffer() {
    const buffered = this.sourceBuffer.buffered
    if (buffered.length === 0) return false
    const start = buffered.start(0)
    const end = buffered.end(buffered.length - 1)
    if (end - start > BUFFER_KEEP_SECONDS) {
      this.sourceBuffer.remove(start, end - BUFFER_KEEP_SECONDS)
      return true
    }
    return false
  },

  nudgeToLiveEdge() {
    const buffered = this.sourceBuffer && this.sourceBuffer.buffered
    if (!buffered || buffered.length === 0) return
    const end = buffered.end(buffered.length - 1)
    // seek into the buffered range on first append / after resets
    if (this.el.currentTime < buffered.start(0)) {
      this.el.currentTime = Math.max(buffered.start(0), end - TARGET_LATENCY_S)
    } else if (end - this.el.currentTime > MAX_DRIFT_S) {
      this.el.currentTime = end - TARGET_LATENCY_S
    }
    if (this.el.paused) this.el.play().catch(() => {})
  },
}

export default MsePlayer
