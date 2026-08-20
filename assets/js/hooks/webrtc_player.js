// WebRTC live player hook (sub-second path).
//
// Signaling over the `webrtc:{camera}` channel: send our SDP offer
// (recvonly video), receive the answer in the reply, trickle ICE both
// ways. Media arrives directly on an RTCPeerConnection; first frame is
// near-instant thanks to the server's GOP replay.
//
// This is the dashboard's default transport, so it also owns the fallback:
// signalling that errors or times out, an SDP exchange that throws, and ICE
// that gives up all report `transport_failed`, and the LiveView flips that
// camera to MSE. It has to be the error path rather than a feature check —
// a browser that supports RTCPeerConnection can still sit behind a network
// that drops the media.
import {Socket} from "phoenix"
import {
  rearmOnReconnect,
  reportInactive,
  reportTransportFailed,
  unwatchFirstFrame,
  watchFirstFrame,
} from "./player_activity"

let sharedSocket = null

function socket() {
  if (!sharedSocket) {
    sharedSocket = new Socket("/socket")
    sharedSocket.connect()
  }
  return sharedSocket
}

const WebrtcPlayer = {
  mounted() {
    this.cameraId = this.el.dataset.cameraId
    watchFirstFrame(this, this.el)
    this.start()
  },

  // The media survives a LiveView remount untouched — this is a WebRTC peer
  // connection, not something the socket carries — so only the server's view
  // of it needs rebuilding.
  reconnected() {
    rearmOnReconnect(this, this.el)
  },

  destroyed() {
    this._destroyed = true
    unwatchFirstFrame(this, this.el)
    reportInactive(this)
    this.teardown()
  },

  async start() {
    this.channel = socket().channel(`webrtc:${this.cameraId}`)
    this.pc = new RTCPeerConnection()

    this.pc.addTransceiver("video", {direction: "recvonly"})
    this.pc.ontrack = e => { this.el.srcObject = e.streams[0] || new MediaStream([e.track]) }
    this.pc.onicecandidate = e => {
      if (e.candidate) this.channel.push("ice", {candidate: e.candidate.toJSON()})
    }
    // "failed" only: ICE has given up for good. "disconnected" is transient
    // by spec and recovers on its own, and "closed" is what our own
    // teardown() produces.
    this.pc.onconnectionstatechange = () => {
      if (this.pc && this.pc.connectionState === "failed") this.fail()
    }

    // Both callbacks below outlive teardown() by a message: the channel is
    // left, not deafened, and fail() can close the connection while the
    // server's answer or a trickled candidate is already in flight.
    this.channel.on("ice", ({candidate}) => {
      if (!this.pc) return
      this.pc.addIceCandidate(candidate).catch(() => {})
    })

    this.channel.join()
      .receive("ok", async () => {
        try {
          const offer = await this.pc.createOffer()
          await this.pc.setLocalDescription(offer)
          this.channel.push("offer", {sdp: offer.sdp})
            // not `await`ed inside this callback: a rejection there escapes
            // the try/catch below as an unhandled promise, and the peer
            // connection sits in "new" forever rather than reaching "failed".
            .receive("ok", ({sdp}) => {
              if (!this.pc) return
              this.pc.setRemoteDescription({type: "answer", sdp}).catch(() => this.fail())
            })
            .receive("error", () => this.fail())
            .receive("timeout", () => this.fail())
        } catch (_e) {
          this.fail()
        }
      })
      .receive("error", () => this.fail())
      .receive("timeout", () => this.fail())
  },

  fail() {
    // A push whose reply is still outstanding when the element goes away
    // delivers its `timeout` to this dead hook up to ~10 s later. Reporting
    // then would flip a camera the operator has since toggled BACK to
    // WebRTC, on the strength of a failure that belongs to the old hook.
    if (this._destroyed) return
    this.teardown()
    reportTransportFailed(this)
  },

  teardown() {
    if (this.pc) {
      // cleared before close() so a late state change cannot re-enter fail()
      // from inside teardown.
      this.pc.onconnectionstatechange = null
      this.pc.close()
      this.pc = null
    }
    if (this.channel) { this.channel.leave(); this.channel = null }
    this.el.srcObject = null
  },
}

export default WebrtcPlayer
