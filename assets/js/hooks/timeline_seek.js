// Detections timeline: clicking a marker (any child with data-seek) seeks
// the video named by data-video-id; the [data-playhead] line tracks the
// video's current position as a percentage of its duration.
//
// The playhead is driven by requestAnimationFrame while playing, not the
// video's `timeupdate` event — browsers fire timeupdate as seldom as ~1Hz, so
// the marker visibly jumps once a second while the video plays smoothly. rAF
// updates in step with the display instead.
//
// Detection markers carry data-t = seconds from the event start, but the clip
// also holds the pre-roll before the event, so a detection is offset into the
// video by that gap. The retained pre-roll is exactly (clip duration − event
// duration), so markers are placed against the real video.duration once it's
// known — which also self-corrects when less than the configured pre-roll was
// captured.
//
// The event page mounts two instances of this hook against the same video: the
// detections timeline, and the tracked-objects panel's #track-moments region.
// The second has no [data-playhead] (so the rAF loop stays idle) and its
// [data-t] rows are not positioned, so the `left` placeMarkers writes is inert
// there — what it wants is the data-seek rewrite, which is the same pre-roll
// correction the markers get.
const TimelineSeek = {
  mounted() {
    this.video = document.getElementById(this.el.dataset.videoId)
    this.playhead = this.el.querySelector("[data-playhead]")

    this.el.addEventListener("click", e => {
      const marker = e.target.closest("[data-seek]")
      if (!marker || !this.video) return
      // data-seek is the pre-roll-adjusted clip time, but placeMarkers only
      // sets it once metadata loads; before that the video can't be seeked
      // meaningfully anyway, so ignore the click
      if (!isFinite(this.video.duration)) return
      this.video.currentTime = parseFloat(marker.dataset.seek)
      this.video.play()
    })

    if (!this.video) return

    this.placeMarkers = () => {
      const d = this.video.duration
      if (!d || !isFinite(d)) return
      const eventSeconds = parseFloat(this.el.dataset.eventSeconds) || 0
      const preRoll = Math.max(d - eventSeconds, 0)
      for (const m of this.el.querySelectorAll("[data-t]")) {
        const clipTime = Math.min(preRoll + (parseFloat(m.dataset.t) || 0), d)
        m.style.left = `${(clipTime / d) * 100}%`
        m.dataset.seek = clipTime
      }
    }

    // data-initial-t is the ?t= param: event-relative seconds, exactly like a
    // marker's data-t, so it gets the same pre-roll correction. Applied once —
    // a later re-render must not yank the video back to where the link pointed.
    this.seekInitial = () => {
      if (this.initialSeeked || this.el.dataset.initialT == null) return
      const d = this.video.duration
      if (!d || !isFinite(d)) return
      const t = parseFloat(this.el.dataset.initialT)
      if (!isFinite(t)) return
      const eventSeconds = parseFloat(this.el.dataset.eventSeconds) || 0
      const preRoll = Math.max(d - eventSeconds, 0)
      this.initialSeeked = true
      this.video.currentTime = Math.min(preRoll + t, d)
    }

    this.onMetadata = () => {
      this.placeMarkers()
      this.seekInitial()
    }

    this.video.addEventListener("loadedmetadata", this.onMetadata)
    this.onMetadata() // metadata may already be available

    if (this.playhead) {
      this.render = () => {
        const d = this.video.duration
        if (!d || !isFinite(d)) return
        const pct = Math.min((this.video.currentTime / d) * 100, 100)
        this.playhead.style.left = `${pct}%`
      }

      this.tick = () => {
        this.render()
        if (!this.video.paused && !this.video.ended) {
          this.raf = requestAnimationFrame(this.tick)
        }
      }

      this.start = () => {
        cancelAnimationFrame(this.raf)
        this.raf = requestAnimationFrame(this.tick)
      }

      // one final render on stop so the marker lands exactly, then idle
      this.stop = () => {
        cancelAnimationFrame(this.raf)
        this.render()
      }

      this.video.addEventListener("play", this.start)
      this.video.addEventListener("pause", this.stop)
      this.video.addEventListener("ended", this.stop)
      this.video.addEventListener("seeked", this.render)
      this.render()
    }
  },

  // markers/duration can change when a live update re-renders the timeline
  updated() {
    if (this.placeMarkers) this.placeMarkers()
  },

  destroyed() {
    cancelAnimationFrame(this.raf)
    if (!this.video) return
    this.video.removeEventListener("loadedmetadata", this.onMetadata)
    this.video.removeEventListener("play", this.start)
    this.video.removeEventListener("pause", this.stop)
    this.video.removeEventListener("ended", this.stop)
    this.video.removeEventListener("seeked", this.render)
  },
}

export default TimelineSeek
