---
title: fmp4-over-Channel MSE live view — demuxer, ring, session-restart handling
tags: [mse, fmp4, mp4, phoenix-channels, video, hls]
date: 2026-07-22
module: Cairn.MP4.Demuxer / Cairn.RingBuffer / CairnWeb.StreamChannel
---

# What worked (validated against a real Reolink RTSP camera)

- **ffmpeg invocation**: `-c:v copy -f mp4 -movflags
  +frag_keyframe+empty_moov+default_base_moof -frag_duration 2000000
  pipe:1` gives a clean `ftyp moov (moof mdat)*` stream on stdout.
- **Pure incremental demuxer**: box framing (incl. 64-bit largesize with a
  `>= 16` sanity guard), init = `ftyp+moov`, fragment = `moof+mdat`,
  pts from `tfdt`, duration from `trun` (fall back to `tfhd`/`trex`
  defaults), RFC 6381 codec (`avc1.` + 3 avcC bytes hex) from
  `moov>trak>mdia>minf>stbl>stsd>avc1>avcC`. Property-test that any
  chunking of the byte stream yields identical events.
- **ffmpeg respawn = new timescale epoch**: pts restart near 0, so a new
  init segment must clear the ring (mixed-epoch pts break eviction), and
  the MSE client must reset its MediaSource when it sees a second "init".
  Ring re-stamps fragment seq with its own monotonic counter so HLS
  `EXT-X-MEDIA-SEQUENCE` stays correct across sessions.
- **Slow-consumer policy**: before each channel push, check the transport
  pid's `message_queue_len`; above ~8, `{:stop, {:shutdown,
  :slow_consumer}}` — the client rejoins fresh at the live edge. Never
  buffer in the channel.
- **Race-free clip boundary**: the ring keeps its own monitored
  subscriber list and `drain_and_subscribe/3` returns buffered fragments
  + subscribes in one GenServer call (PubSub can't do this atomically —
  `Phoenix.PubSub.subscribe/2` subscribes the *caller*).
- **-stimeout vs -timeout**: probe `ffmpeg -h demuxer=rtsp` once and cache;
  `-reconnect*` flags are HTTP-only (useful for Reolink FLV URLs, useless
  for RTSP — RTSP resilience is the respawn/watchdog loop).
