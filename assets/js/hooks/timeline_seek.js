// Clicking a labels-timeline marker (any child with data-seek) seeks the
// video element named by data-video-id to that offset.
const TimelineSeek = {
  mounted() {
    this.el.addEventListener("click", e => {
      const marker = e.target.closest("[data-seek]")
      if (!marker) return
      const video = document.getElementById(this.el.dataset.videoId)
      if (!video) return
      video.currentTime = parseFloat(marker.dataset.seek)
      video.play()
    })
  },
}

export default TimelineSeek
