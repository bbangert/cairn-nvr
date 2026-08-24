// Bbox overlay: draws each selected tracked object's path over the event clip.
//
// The data is the per-event sidecar written by Cairn.TrackPath — gzipped
// MessagePack, served with content-encoding: gzip so `fetch` unwraps it for
// us. What it hands back is the *stored* map: columnar, delta-encoded, and
// quantized to round(v * 10_000). Reconstructing it is this file's first job,
// and lib/cairn/track_path.ex's moduledoc is the contract being mirrored — the
// two implementations have no code in common, so a change there is a change
// here.
//
// Frame sync is requestVideoFrameCallback: it fires at the video's own frame
// rate with a frame-accurate mediaTime, where rAF gives display-rate jitter and
// `timeupdate` is far too coarse to draw a box from (hooks/timeline_seek.js
// avoids it for the same reason). rVFC does not fire while paused, so
// pause/seek/scrub draw once from their own handlers instead.
//
// Known gap, for the manual smoke: the native fullscreen button promotes the
// <video> alone, and this canvas is its sibling rather than its child, so the
// boxes disappear for the duration instead of scaling with the frame.
// Fullscreening the positioned wrapper is the fix, and it means intercepting a
// control the browser owns — not attempted in v1.
import {decode as decodeMsgpack} from "../vendor_msgpack.js"

// Native controls occupy roughly this much of the bottom of the video. Boxes
// are clipped above it while they're showing, so a box over the timeline strip
// doesn't fight the scrubber. A heuristic, not a measurement: there is no API
// for the controls' geometry, and it differs per browser.
const CONTROLS_HEIGHT = 44
// See sampleAt. A FULL second of absent detection is a real gap, not a
// sample period, at every tier-1 rate (periods run ~130-530ms) — the
// boundary itself counts as a gap (>=), or exactly one second of synthetic
// motion would still draw.
const MAX_LERP_GAP_MS = 1000
const BOX_HOLD_MS = 300

const BOX_RADIUS = 3
const HALO = "rgba(4, 8, 12, 0.55)"
const CHIP_BG = "rgba(11, 15, 20, 0.82)"
const CHIP_FONT = "11px ui-sans-serif, system-ui, sans-serif"

// First element absolute, every later one a difference from its predecessor.
function undelta(column) {
  const out = new Array(column.length)
  let acc = 0
  for (let i = 0; i < column.length; i++) {
    acc += column[i]
    out[i] = acc
  }
  return out
}

function dequantize(column) {
  const out = new Float64Array(column.length)
  let acc = 0
  for (let i = 0; i < column.length; i++) {
    acc += column[i]
    out[i] = acc / 10000
  }
  return out
}

function parseJson(raw, fallback) {
  try {
    const value = JSON.parse(raw)
    return value === null ? fallback : value
  } catch (_e) {
    return fallback
  }
}

function roundedRect(ctx, x, y, w, h, r) {
  const rr = Math.min(r, w / 2, h / 2)
  ctx.beginPath()
  ctx.moveTo(x + rr, y)
  ctx.arcTo(x + w, y, x + w, y + h, rr)
  ctx.arcTo(x + w, y + h, x, y + h, rr)
  ctx.arcTo(x, y + h, x, y, rr)
  ctx.arcTo(x, y, x + w, y, rr)
  ctx.closePath()
}

const TrackOverlay = {
  mounted() {
    this.video = document.getElementById(this.el.dataset.videoId)
    this.canvas = this.el.querySelector("canvas")
    if (!this.video || !this.canvas) return

    this.paths = null
    this.readSelection()

    this.draw = () => this.render()
    this.onPlay = () => this.startLoop()
    this.onPause = () => this.render()
    this.onSeeked = () => this.render()
    this.onLoaded = () => this.render()

    this.video.addEventListener("play", this.onPlay)
    this.video.addEventListener("pause", this.onPause)
    this.video.addEventListener("ended", this.onPause)
    this.video.addEventListener("seeked", this.onSeeked)
    this.video.addEventListener("loadedmetadata", this.onLoaded)

    this.observer = new ResizeObserver(() => this.render())
    this.observer.observe(this.canvas)

    this.load()
  },

  // The selected set and the object colours both arrive as data attributes, so
  // a toggle is a patched attribute and a redraw, with no round trip of its own.
  updated() {
    this.readSelection()
    this.render()
  },

  destroyed() {
    if (this.rvfc && this.video && this.video.cancelVideoFrameCallback) {
      this.video.cancelVideoFrameCallback(this.rvfc)
    }
    if (this.abort) this.abort.abort()
    if (this.observer) this.observer.disconnect()
    if (!this.video) return
    this.video.removeEventListener("play", this.onPlay)
    this.video.removeEventListener("pause", this.onPause)
    this.video.removeEventListener("ended", this.onPause)
    this.video.removeEventListener("seeked", this.onSeeked)
    this.video.removeEventListener("loadedmetadata", this.onLoaded)
  },

  // Both attributes are JSON. The selection is a list of whatever the sidecar
  // keys its tracks by — ULIDs on the tracked lane, labels on the presence one —
  // and a label is model-supplied text that may contain a comma, so it cannot be
  // a delimited string. CairnWeb.EventLive writes both.
  readSelection() {
    this.selected = new Set(parseJson(this.el.dataset.selected, []))
    this.objects = parseJson(this.el.dataset.objects, {})
  },

  load() {
    const url = this.el.dataset.sidecarUrl
    this.abort = new AbortController()
    fetch(url, {signal: this.abort.signal})
      .then(resp => (resp.ok ? resp.arrayBuffer() : Promise.reject(resp.status)))
      .then(buf => {
        this.paths = this.reconstruct(decodeMsgpack(new Uint8Array(buf)))
        this.render()
        if (!this.video.paused) this.startLoop()
      })
      .catch(err => {
        // A missing or unreadable sidecar draws nothing, which the panel
        // already explains when the server knew at render time. This arm also
        // catches what nobody explains: a truncated or malformed file, a decode
        // that threw, a teardown abort. A blank overlay looks identical in
        // every case, so the reason goes to the console with the URL it came
        // from — the only trace a browser session leaves.
        console.error("track overlay: sidecar unavailable, drawing no boxes", {url, error: err})
        this.paths = null
      })
  },

  // Stored map -> per-track arrays of absolute times and normalized boxes.
  reconstruct(file) {
    const ts = undelta(file["ts"] || [])
    const tracks = (file["tracks"] || []).map(t => {
      const idx = undelta(t["ti"] || [])
      return {
        id: t["id"],
        label: t["label"],
        times: idx.map(i => ts[i]),
        x: dequantize(t["x"] || []),
        y: dequantize(t["y"] || []),
        w: dequantize(t["w"] || []),
        h: dequantize(t["h"] || []),
        // v2's per-sample score column: round(score*1000) delta-encoded,
        // -1 for "no score" (a predicted box). Absent in v1 files.
        s: undelta(t["s"] || []).map(v => (v < 0 ? null : v / 1000)),
        cursor: 0,
      }
    })
    // What a track's `id` is, and so what the selected set and the colour map
    // are keyed by: a tracker identity ("object", and the only thing files
    // written before this field existed hold) or the label itself ("label",
    // the tier-1 presence lane, which has no tracker to mint identities).
    // lib/cairn/track_path.ex's header section is the contract.
    return {anchor: file["anchor"] || null, identity: file["identity"] || "object", tracks}
  },

  trackKey(track) {
    return this.paths.identity === "label" ? track.label : track.id
  },

  startLoop() {
    if (!this.video.requestVideoFrameCallback) {
      // No rVFC: draw what we can on the events we do get.
      this.render()
      return
    }
    if (this.rvfc) this.video.cancelVideoFrameCallback(this.rvfc)
    const tick = (_now, metadata) => {
      this.render(metadata && metadata.mediaTime)
      if (!this.video.paused && !this.video.ended) {
        this.rvfc = this.video.requestVideoFrameCallback(tick)
      }
    }
    this.rvfc = this.video.requestVideoFrameCallback(tick)
  },

  // Where the event's t=0 sits inside the clip, in seconds. Subtract it from a
  // clip position to get seconds since the event's started_at; the caller
  // scales that to the milliseconds the sidecar's `ts` column is in.
  //
  // This is Cairn.TrackPath.anchor_clip_ms/2 at t_ms = 0, mirrored: the anchor
  // holds two pairings of a media position with a wall clock, and the live one
  // — the first fragment written from the live stream — is preferred over the
  // drain one, which understates the media that existed by however much of a
  // fragment ffmpeg had not written out yet. That understate makes boxes run
  // ahead of the subject, and preferring the live pair is what removes it.
  //
  // It removes that and only that. Boxes running ahead had a second cause —
  // a clip whose first fragment fell mid-GOP, losing its head to the remux and
  // shifting both pairs equally — which no choice between the halves could
  // have fixed; that one is fixed where the clip is written. The Elixir
  // moduledoc has the full argument and is the contract this file is
  // answerable to.
  //
  // Residual, deliberately uncorrected: even the live pair is late by whatever
  // the camera, the transport and the demux cost — roughly 100 ms, roughly
  // constant per setup, and still in the "boxes ahead" direction. If that ever
  // earns a constant it goes in anchor_clip_ms/2 and is mirrored here; a number
  // added in this file alone would silently disagree with the poster frame.
  //
  // With neither pairing usable we fall back to the estimate the detections
  // timeline already uses — duration − event duration is exactly the retained
  // pre-roll.
  // Read per draw rather than cached at mount: the attribute is a LiveView
  // assign, so a re-render can change it under a live page.
  annotationOffsetSeconds() {
    return parseFloat(this.el.dataset.annotationOffset) || 0
  },

  clipOffsetSeconds() {
    const a = this.paths && this.paths.anchor
    const d = this.video.duration
    if (a) {
      const started = a["event_started_ms"]
      const live = this.anchorOffset(a["live_media_ms"], a["live_wall_ms"], started, d)
      if (live !== null) return live
      const drain = this.anchorOffset(a["drained_span_ms"], a["drain_wall_ms"], started, d)
      if (drain !== null) return drain
    }
    if (!isFinite(d)) return 0
    const eventSeconds = parseFloat(this.el.dataset.eventSeconds) || 0
    return Math.max(d - eventSeconds, 0)
  },

  // One half of the anchor, or null to try the next thing. A msgpack file can
  // hold anything, so the three fields have to be numbers and the media
  // position non-negative — a negative one is an ffmpeg respawn having restarted
  // pts under the anchor, and the other half is the better answer.
  //
  // The two bounds on the result are this reader's own, and anchor_clip_ms/2
  // has neither: it cannot see the video element, so it refuses anything before
  // the clip and leaves the far end to its caller. Here, a half placing the
  // event past the end of the video is no use, and one placing it up to a
  // second before the start is clamped rather than rejected — a fraction of a
  // second out still beats the duration−event estimate underneath.
  anchorOffset(mediaMs, wallMs, startedMs, duration) {
    if (typeof mediaMs !== "number" || typeof wallMs !== "number") return null
    if (typeof startedMs !== "number" || !(mediaMs >= 0)) return null
    const offset = (mediaMs + startedMs - wallMs) / 1000
    if (!isFinite(offset) || offset < -1) return null
    if (isFinite(duration) && offset > duration) return null
    return Math.max(offset, 0)
  },

  // The sample at `tMs`, interpolated between the two keyframes around it, or
  // null outside the path. A monotonic cursor makes playback O(1) per frame;
  // a seek backwards falls back to a binary search, once.
  //
  // Interpolation stops at MAX_LERP_GAP_MS: consecutive samples sit a sample
  // period apart (~130-530ms across the tier-1 rate range), so a wider gap is
  // detection genuinely absent — the model lost the object, or on a
  // label-keyed sidecar the one path per label teleported between bodies —
  // and lerping across it invents a box floating through space nothing was
  // detected in (Ben's clip b516cd29, 2026-08-20; limit his call at ~1s).
  // The endpoint sample still shows for BOX_HOLD_MS: a detection that
  // precedes a gap is a real detection, and without the hold it would render
  // for a single frame.
  sampleAt(track, tMs) {
    const times = track.times
    const n = times.length
    if (n === 0 || tMs < times[0] || tMs > times[n - 1]) return null
    if (n === 1) return [track.x[0], track.y[0], track.w[0], track.h[0]]
    // (sampleScoreAt below leans on the cursor this leaves behind.)

    if (tMs < times[track.cursor]) {
      let lo = 0
      let hi = n - 1
      while (lo < hi) {
        const mid = (lo + hi) >> 1
        if (times[mid] <= tMs) lo = mid + 1
        else hi = mid
      }
      track.cursor = Math.max(lo - 1, 0)
    }
    while (track.cursor < n - 2 && times[track.cursor + 1] <= tMs) track.cursor++

    const i = track.cursor
    const t0 = times[i]
    const t1 = times[i + 1]
    if (t1 - t0 >= MAX_LERP_GAP_MS) {
      // At or past t1 the pair's second sample is the CURRENT detection —
      // only the terminal pair can be here (the cursor advances past every
      // other), and without this a track whose last pair spans a gap never
      // renders its final real detection.
      if (tMs >= t1) return [track.x[i + 1], track.y[i + 1], track.w[i + 1], track.h[i + 1]]
      // Hold only the OBSERVED endpoint: the sample before the gap was a
      // real detection worth a brief hold, but rendering t1's box before t1
      // would invent an annotation inside the gap — and disagree with the
      // stepped score, which stays t0's until playback reaches t1.
      if (tMs - t0 <= BOX_HOLD_MS) return [track.x[i], track.y[i], track.w[i], track.h[i]]
      return null
    }
    const f = t1 > t0 ? Math.min(Math.max((tMs - t0) / (t1 - t0), 0), 1) : 0
    return [
      track.x[i] + (track.x[i + 1] - track.x[i]) * f,
      track.y[i] + (track.y[i + 1] - track.y[i]) * f,
      track.w[i] + (track.w[i + 1] - track.w[i]) * f,
      track.h[i] + (track.h[i + 1] - track.h[i]) * f,
    ]
  },

  // The score at the sample nearest the cursor sampleAt just positioned —
  // scores are claims about detections, so they step rather than lerp.
  // null when the file predates v2's "s" column or the sample is a
  // scoreless prediction.
  sampleScoreAt(track, tMs) {
    if (!track.s || track.s.length === 0) return null
    // A step function, never "nearest": a score is a detection claim, so it
    // holds from its own sample until the next one — showing the next
    // sample's number from the midpoint would display a detection's
    // confidence before that detection happened.
    const i = track.cursor
    const t1 = track.times[i + 1]
    const j = t1 != null && tMs >= t1 ? i + 1 : i
    const s = track.s[Math.min(j, track.s.length - 1)]
    return s == null ? null : s
  },

  render(mediaTime) {
    const canvas = this.canvas
    const rect = canvas.getBoundingClientRect()
    if (!rect.width || !rect.height) return

    const dpr = window.devicePixelRatio || 1
    const backingW = Math.round(rect.width * dpr)
    const backingH = Math.round(rect.height * dpr)
    if (canvas.width !== backingW || canvas.height !== backingH) {
      canvas.width = backingW
      canvas.height = backingH
    }
    const ctx = canvas.getContext("2d")
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
    ctx.clearRect(0, 0, rect.width, rect.height)

    if (!this.paths || this.selected.size === 0) return

    const vw = this.video.videoWidth
    const vh = this.video.videoHeight
    if (!vw || !vh) return

    // object-fit: contain — the frame is centred inside the box with bars on
    // whichever axis has slack.
    const scale = Math.min(rect.width / vw, rect.height / vh)
    const dispW = vw * scale
    const dispH = vh * scale
    const offX = (rect.width - dispW) / 2
    const offY = (rect.height - dispH) / 2

    const clipT = mediaTime != null ? mediaTime : this.video.currentTime
    // The one place clip time becomes sidecar time, and so the one place the
    // camera's annotation offset belongs. Subtracted here because we are going
    // record-clock → detect-clock: a positive offset means the boxes should
    // appear LATER on the clip, which is the same as reading an EARLIER
    // sidecar sample at any given moment. Nothing in the file is shifted —
    // re-rendering with a new offset needs only a reload.
    const tMs = (clipT - this.clipOffsetSeconds() - this.annotationOffsetSeconds()) * 1000

    const controlsVisible = this.video.controls && !document.fullscreenElement
    const bottom = controlsVisible ? Math.max(rect.height - CONTROLS_HEIGHT, 0) : rect.height

    ctx.save()
    ctx.beginPath()
    ctx.rect(0, 0, rect.width, bottom)
    ctx.clip()

    for (const track of this.paths.tracks) {
      const key = this.trackKey(track)
      if (!this.selected.has(key)) continue
      const box = this.sampleAt(track, tMs)
      if (!box) continue

      const meta = this.objects[key] || {}
      const color = meta.color || "#5fc0f5"
      const x = offX + box[0] * dispW
      const y = offY + box[1] * dispH
      const w = box[2] * dispW
      const h = box[3] * dispH
      if (w <= 0 || h <= 0) continue

      roundedRect(ctx, x, y, w, h, BOX_RADIUS)
      ctx.lineWidth = 4
      ctx.strokeStyle = HALO
      ctx.stroke()
      ctx.lineWidth = 2
      ctx.strokeStyle = color
      ctx.stroke()

      // Absent column and null sample are different claims: a v1 file
      // never carried scores, so the panel's static best_score is the only
      // number there is; a v2 null marks THIS sample as scoreless
      // (predicted box), and showing best_score would dress a guess up as
      // a detection. Label-only chip for the latter.
      const sampleScore = this.sampleScoreAt(track, tMs)
      const hasScoreColumn = track.s && track.s.length > 0
      const score =
        sampleScore != null ? sampleScore.toFixed(2) : hasScoreColumn ? null : meta.score
      this.drawChip(ctx, x, y, meta.label || track.label, score, color)
    }

    ctx.restore()
  },

  // The chip sits above-left of the box and flips inside it when there is no
  // room above. The score is the sample's own (v2's "s" column) — the number
  // that varies as the model's confidence does. Only a v1 file (no "s"
  // column at all) falls back to the panel's static `best_score`; a v2
  // scoreless sample (predicted box) renders the label alone.
  drawChip(ctx, x, y, label, score, color) {
    if (!label) return
    const text = score && score !== "—" ? `${label} ${score}` : label
    ctx.font = CHIP_FONT
    ctx.textBaseline = "middle"
    const padX = 5
    const chipH = 16
    const chipW = ctx.measureText(text).width + padX * 2
    const above = y - chipH - 3
    const top = above >= 0 ? above : y + 3

    ctx.fillStyle = CHIP_BG
    roundedRect(ctx, x, top, chipW, chipH, BOX_RADIUS)
    ctx.fill()
    ctx.fillStyle = color
    ctx.fillText(text, x + padX, top + chipH / 2)
  },
}

export default TrackOverlay
