// Detections timeline: clicking a marker (any child with data-seek) seeks
// the video named by data-video-id; the [data-playhead] line tracks the
// video's current position as a percentage of its duration.
const TimelineSeek = {
  mounted() {
    this.video = document.getElementById(this.el.dataset.videoId)
    this.playhead = this.el.querySelector("[data-playhead]")

    this.el.addEventListener("click", e => {
      const marker = e.target.closest("[data-seek]")
      if (!marker || !this.video) return
      this.video.currentTime = parseFloat(marker.dataset.seek)
      this.video.play()
    })

    if (this.video && this.playhead) {
      this.onTime = () => {
        const d = this.video.duration
        if (!d || !isFinite(d)) return
        const pct = Math.min((this.video.currentTime / d) * 100, 100)
        this.playhead.style.left = `${pct}%`
      }
      this.video.addEventListener("timeupdate", this.onTime)
    }
  },

  destroyed() {
    if (this.video && this.onTime) this.video.removeEventListener("timeupdate", this.onTime)
  },
}

export default TimelineSeek
