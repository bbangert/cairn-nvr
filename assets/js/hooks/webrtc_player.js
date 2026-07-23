// WebRTC live player hook (sub-second path).
//
// Signaling over the `webrtc:{camera}` channel: send our SDP offer
// (recvonly video), receive the answer in the reply, trickle ICE both
// ways. Media arrives directly on an RTCPeerConnection; first frame is
// near-instant thanks to the server's GOP replay.
import {Socket} from "phoenix"

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
    this.start()
  },

  destroyed() {
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

    this.channel.on("ice", ({candidate}) => {
      this.pc.addIceCandidate(candidate).catch(() => {})
    })

    this.channel.join()
      .receive("ok", async () => {
        const offer = await this.pc.createOffer()
        await this.pc.setLocalDescription(offer)
        this.channel.push("offer", {sdp: offer.sdp})
          .receive("ok", async ({sdp}) => {
            await this.pc.setRemoteDescription({type: "answer", sdp})
          })
      })
      .receive("error", () => this.teardown())
  },

  teardown() {
    if (this.pc) { this.pc.close(); this.pc = null }
    if (this.channel) { this.channel.leave(); this.channel = null }
    this.el.srcObject = null
  },
}

export default WebrtcPlayer
