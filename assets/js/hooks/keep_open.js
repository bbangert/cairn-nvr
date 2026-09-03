// A <details> element's `open` is client state — the server renders no
// `open` attribute, so every patch that re-renders this subtree would
// collapse a section the operator had opened, and the form re-renders on
// every keystroke. Recorded before the patch, put back after it.
export default {
  beforeUpdate() { this.wasOpen = this.el.open },
  updated() { this.el.open = this.wasOpen },
}
