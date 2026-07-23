// Copies data-copy to the clipboard on click; the inner Material Symbols
// icon flips to a check for 1.5s as feedback.
const CopyText = {
  mounted() {
    this.el.addEventListener("click", () => {
      const text = this.el.dataset.copy
      if (!text) return
      navigator.clipboard.writeText(text).then(() => {
        const icon = this.el.querySelector(".ms")
        if (!icon) return
        const original = icon.textContent
        icon.textContent = "check"
        setTimeout(() => { icon.textContent = original }, 1500)
      }).catch(() => {})
    })
  },
}

export default CopyText
