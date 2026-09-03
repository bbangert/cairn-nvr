// A <dialog> is only a dialog once showModal() has been called on it: focus
// trap, inert background, Esc to close, ::backdrop. No attribute the server
// renders can make that call, so the server dispatches an event at the
// element and this turns it into the call. Idempotent on both sides —
// showModal() on an open dialog throws, close() on a closed one is a no-op.
export default {
  mounted() {
    this.show = () => { if (!this.el.open) this.el.showModal() }
    this.hide = () => { if (this.el.open) this.el.close() }
    this.el.addEventListener("cairn:show-modal", this.show)
    this.el.addEventListener("cairn:hide-modal", this.hide)
  },

  destroyed() {
    this.el.removeEventListener("cairn:show-modal", this.show)
    this.el.removeEventListener("cairn:hide-modal", this.hide)
  },
}
