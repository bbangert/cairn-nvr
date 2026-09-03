// A <dialog> is only a dialog once showModal() has been called on it: focus
// trap, inert background, Esc to close, ::backdrop. No attribute the server
// renders can make that call, so the server dispatches an event at the
// element (open/close) or pushes one to this hook (close only, when a write
// under the dialog answers) and this turns either into the call. Idempotent
// on both sides — showModal() on an open dialog throws, close() on a closed
// one is a no-op.
export default {
  mounted() {
    this.show = () => { if (!this.el.open) this.el.showModal() }
    this.hide = () => { if (this.el.open) this.el.close() }
    this.el.addEventListener("cairn:show-modal", this.show)
    this.el.addEventListener("cairn:hide-modal", this.hide)

    // Server-pushed, not element-dispatched: the dialog is `phx-update="ignore"`,
    // so an error card rendered behind it (a failed or unconfirmed remove)
    // would otherwise sit inert under an open, focus-trapping modal with no
    // way for the operator to see it. Scoped to this element's own id since
    // `push_event/3` reaches every hook on the page listening for the name.
    this.handleEvent("cairn:close-dialog", ({ id }) => {
      if (this.el.id === id && this.el.open) this.el.close()
    })
  },

  destroyed() {
    this.el.removeEventListener("cairn:show-modal", this.show)
    this.el.removeEventListener("cairn:hide-modal", this.hide)
  },
}
