# Home Assistant Camera Streaming API Research
## 2024.11 – 2025/2026 Native WebRTC Support

**Research Date:** July 2026  
**Target:** Custom NVR integration (Cairn) exposing WebRTC and RTSP streams to HA  
**Scope:** Python/HA-side camera entity API only — no Elixir backend

---

## 1. Camera Entity Base Class & Snapshots

### Imports
```python
from homeassistant.components.camera import Camera, CameraEntityFeature
```

### Camera Class Basics
Derive your camera entity from `homeassistant.components.camera.Camera`:

```python
class CairnCamera(Camera):
    """Cairn NVR camera entity."""
    
    @property
    def supported_features(self) -> CameraEntityFeature:
        """Return supported features."""
        return CameraEntityFeature.STREAM  # or | CameraEntityFeature.ON_OFF
    
    @property
    def is_streaming(self) -> bool:
        """Return True if currently streaming."""
        return True
    
    @property
    def is_recording(self) -> bool:
        """Return True if currently recording."""
        return False
```

### CameraEntityFeature Enum
```python
class CameraEntityFeature(IntFlag):
    ON_OFF = 1       # Supports turn_on/turn_off
    STREAM = 2       # Supports streaming
```

Set `supported_features` bitwise OR'd combination of flags.

### Still Image (Snapshot) Methods

**Option A: Synchronous (blocks event loop)**
```python
def camera_image(
    self, width: int | None = None, height: int | None = None
) -> bytes | None:
    """Return bytes of camera image.
    
    Width/height: preserve aspect ratio when scaling.
    Returns raw bytes of image (JPEG, PNG, etc).
    """
```

**Option B: Asynchronous (preferred)**
```python
async def async_camera_image(
    self, width: int | None = None, height: int | None = None
) -> bytes | None:
    """Return bytes of camera image (async)."""
```

**How HA serves snapshots:**
- HA's camera card calls `/api/camera_proxy/<entity_id>` endpoint
- Endpoint calls `async_camera_image()` (or `camera_image()` in executor)
- Returns raw bytes; HA handles Content-Type inference
- Width/height params passed by frontend; scaling must preserve aspect ratio

**Gotcha:** Do NOT block the event loop in `camera_image()`. Use `async_camera_image()` or offload to executor with `hass.async_add_executor_job()`.

---

## 2. Native WebRTC Support (2024.11+)

### Overview
Home Assistant 2024.11 introduced **native async WebRTC signaling** for camera entities. Integrations can now provide low-latency P2P streams without relying on `stream_source` → HLS conversion.

**Key benefit:** Sub-second latency vs. 5-10s for HLS.

### Required Methods & Types

#### Method 1: Handle WebRTC Offer
```python
async def async_handle_async_webrtc_offer(
    self,
    offer_sdp: str,
    session_id: str,
    send_message: WebRTCSendMessage,
) -> None:
    """Handle incoming WebRTC offer (SDP).
    
    Args:
        offer_sdp: Remote SDP offer from browser
        session_id: Unique session ID (for tracking)
        send_message: Async callback to send WebRTC messages back
    
    This is called by HA when frontend initiates WebRTC connection.
    Integration must:
      1. Create Answer SDP
      2. Call send_message(WebRTCAnswer(answer=answer_sdp))
      3. Set up ICE candidate listening
      4. Forward any errors via send_message(WebRTCError(...))
    """
```

#### Method 2: Handle ICE Candidates
```python
async def async_on_webrtc_candidate(
    self, session_id: str, candidate: RTCIceCandidate
) -> None:
    """Handle incoming ICE candidate from browser.
    
    Args:
        session_id: Matches the session from offer
        candidate: ICE candidate (sdp_mline_index, sdp_mid, candidate)
    
    Forward candidate to WebRTC peer (typically go2rtc or local peer).
    """
```

#### Method 3: Close Session
```python
@callback
def close_webrtc_session(self, session_id: str) -> None:
    """Close WebRTC session.
    
    Called by HA when user closes camera or connection drops.
    Clean up ICE listeners, close peer connections, etc.
    """
```

#### Method 4: Client Configuration (Optional)
```python
async def async_get_webrtc_client_configuration(
    self,
) -> WebRTCClientConfiguration:
    """Return WebRTC client configuration.
    
    Optional. Used by HA to configure browser's RTCPeerConnection.
    Example: STUN/TURN servers, codecs, etc.
    
    Returns:
        WebRTCClientConfiguration(
            iceServers=[...],  # STUN/TURN servers
            # Add other WebRTC config as needed
        )
    """
```

### Type Definitions
```python
from homeassistant.components.camera import (
    WebRTCAnswer,          # answer: WebRTCAnswer(answer=answer_sdp)
    WebRTCCandidate,       # Represents ICE candidate
    WebRTCMessage,         # Base message type
    WebRTCClientConfiguration,  # Client config
)

# WebRTCSendMessage is a callable:
# send_message: Callable[[WebRTCAnswer | WebRTCError], Awaitable[None]]
# Usage: await send_message(WebRTCAnswer(answer=answer_sdp))
```

### What Integration Must Do vs. HA Provides

**Integration MUST implement:**
1. Generate Answer SDP in response to offer
2. Exchange ICE candidates bidirectionally
3. Manage WebRTC peer connection lifecycle (typically to camera hardware or go2rtc)
4. Send errors back via `send_message`
5. Handle session cleanup

**HA Provides:**
1. Frontend UI (camera card with WebRTC player)
2. Offer generation and candidate collection from browser
3. STUN server infrastructure (Open Home Foundation)
4. TURN relay servers (Cloud subscribers only)
5. Automatic fallback to HLS if WebRTC unavailable

### Detection & Automatic Frontend Switching
As of 2024.11, HA **automatically detects** WebRTC capability by checking if entity implements `async_handle_async_webrtc_offer`. No need to set `frontend_stream_type` property (deprecated, removal 2025.6).

---

## 3. Alternative Path: StreamSource (RTSP → HLS)

### Use Case
When WebRTC is unavailable or overkill; provides fallback streaming via Home Assistant's built-in `stream` component.

### Implementation
```python
@property
async def stream_source(self) -> str | None:
    """Return source for stream component.
    
    Returns: RTSP URL or other ffmpeg-compatible URL string.
    Requires: CameraEntityFeature.STREAM flag.
    """
    return "rtsp://camera-ip:554/stream"
```

### HA Stream Component Flow
1. Integration sets `stream_source` property
2. HA's `stream` component consumes the URL
3. FFmpeg transcodes RTSP → HLS (HTTP Live Streaming)
4. Browser plays HLS stream from HA (5-10s latency typical)
5. HA caches HLS playlist; on-demand transcoding

### Codec Support
- **Input (RTSP):** H.264, H.265, MPEG4, etc. (any FFmpeg-compatible)
- **Output (HLS):** H.264 (default), can transcode H.265 if needed
- **Browser playback:** HLS via Media Source Extensions (MSE) or fallback

### Advantages
- **Simplicity:** Just return a URL; HA handles transcoding
- **Compatibility:** Works on all browsers (HLS is ubiquitous)
- **Fallback:** Automatic if WebRTC unavailable

### Disadvantages
- **Latency:** 5-10+ seconds (FFmpeg transcoding overhead)
- **CPU:** Transcoding burns CPU; not efficient for many cameras
- **Codec loss:** H.265 cameras transcoded to H.264 (re-encoding overhead)

### Comparison: StreamSource vs. WebRTC
| Aspect | StreamSource (RTSP→HLS) | WebRTC |
|--------|------------------------|--------|
| Latency | 5-10s+ | <1s (P2P) |
| CPU Cost | High (FFmpeg transcode) | Low (direct P2P or proxy) |
| Codec Support | H.264 output only; transcodes H.265 | H.264 native; H.265 in Safari/Chrome 136+ |
| Complexity | Minimal (just URL) | Moderate (SDP/ICE management) |
| Browser Support | Universal (HLS) | Universal (WebRTC in modern browsers) |
| Fallback | Yes (if WebRTC fails) | Requires `stream_source` as fallback |
| Recording | Supported by stream component | Bypasses recording (WebRTC-only streams) |

---

## 4. go2rtc Integration & Built-in WebRTC Support

### What is go2rtc?
- **Purpose:** Camera streaming proxy supporting RTSP, WebRTC, RTMP, HTTP-FLV, HLS, HomeKit, FFmpeg
- **HA Integration:** Built into HA 2024.11+ (Docker/Supervised/OS installations)
- **Role:** Converts RTSP → WebRTC (and other formats) for lower latency

### Deployment Model
- **Docker/OS/Supervised:** go2rtc runs automatically, no manual setup
- **Python (core) installations:** go2rtc NOT included; must install separately or use custom approach
- **Configuration:** YAML at `config/go2rtc.yaml` (auto-created by HA)

### Ports (Docker/HA-managed)
- HA prefixes all ports with "1" to avoid conflicts:
  - API: 1984 (default 984)
  - WebRTC: 18555 (default 8555)
  - Debug UI: 11984 (default 1984)

### For Custom NVR Integration: Do You Need go2rtc?

**Scenario A: Cairn exposes WebRTC natively**
- No; implement `async_handle_async_webrtc_offer` directly
- HA handles signaling; your NVR handles peer connection
- Simplest approach

**Scenario B: Cairn exposes only RTSP**
- Yes; rely on go2rtc to proxy RTSP → WebRTC
- HA's go2rtc integration registers as WebRTC provider
- Registration: `async_register_webrtc_provider(domain, handler)` (see docs)

**Scenario C: Cairn exposes WebRTC + RTSP**
- Implement WebRTC directly (fastest path)
- Optionally expose RTSP as fallback for `stream_source`
- Best of both worlds; no go2rtc needed

### Codec Support in go2rtc
- **Input:** RTSP (H.264, H.265, others)
- **WebRTC Output:** H.264 native; H.265 in Safari + Chrome 136+
- **HLS Output:** H.264 (transcoded from H.265 if needed)
- **Transcoding:** Automatic, but CPU-intensive

---

## 5. Practical Recommendation for Cairn NVR

### Scenario: Cairn already produces WebRTC + RTSP streams

**PRIMARY PATH (Recommended):**
1. **Implement native WebRTC in Cairn camera entity**
   - Methods: `async_handle_async_webrtc_offer`, `async_on_webrtc_candidate`, `close_webrtc_session`
   - Cairn's backend (Elixir/WebRTC stack) handles SDP/ICE generation and peer connection
   - HA provides browser signaling and fallback
   - **Result:** Sub-second latency, zero re-encoding, minimal code

2. **Add RTSP fallback via `stream_source`**
   - Property returns RTSP URL
   - Automatically used by HA's HLS component if WebRTC unavailable
   - **Gotcha:** Requires `CameraEntityFeature.STREAM` flag; HA will spawn FFmpeg for transcoding

3. **Code sketch:**
   ```python
   class CairnCamera(Camera):
       supported_features = CameraEntityFeature.STREAM
       
       async def async_camera_image(self, ...):
           """Fetch still image."""
           return await self.coordinator.async_snapshot()
       
       @property
       async def stream_source(self) -> str | None:
           """RTSP fallback."""
           return f"rtsp://{self.coordinator.host}:554/{self.stream_id}"
       
       async def async_handle_async_webrtc_offer(
           self, offer_sdp, session_id, send_message
       ):
           """Native WebRTC."""
           answer_sdp = await self.coordinator.webrtc_offer(offer_sdp, session_id)
           await send_message(WebRTCAnswer(answer=answer_sdp))
           # Set up ICE listener...
       
       async def async_on_webrtc_candidate(self, session_id, candidate):
           """Forward ICE candidate to Cairn backend."""
           await self.coordinator.webrtc_candidate(session_id, candidate)
       
       @callback
       def close_webrtc_session(self, session_id):
           """Clean up."""
           self.coordinator.close_session(session_id)
   ```

### Gotchas & Codec Notes

1. **H.265 via WebRTC:** Supported in Safari and Chrome 136+, but not all browsers. RTSP fallback should use H.264 or accept H.265 transcoding cost.

2. **Audio:** WebRTC supports audio; ensure Cairn backend provides audio tracks in SDP offer.

3. **go2rtc Dependency:** NOT required if Cairn implements WebRTC natively. Use only for RTSP-only cameras.

4. **Recording:** WebRTC streams bypass HA's recording component. If recording needed, use `stream_source` as primary and WebRTC as optimization layer.

5. **Latency:** WebRTC (sub-1s) >> HLS (5-10s). Prefer WebRTC for live view.

6. **STUN/TURN:** HA provides free STUN servers (Open Home Foundation). Cloud subscribers get TURN relays for remote access. No integration code needed.

---

## 6. Source Summary & Authority

### Tier 1 (Authoritative)
- **[Camera Entity Docs](https://developers.home-assistant.io/docs/core/entity/camera/)** – Official HA developer docs; method signatures, examples
- **[Camera API Changes (2024.11)](https://developers.home-assistant.io/blog/2024/11/26/camera-deprecations/)** – Deprecation announcement; migration guide
- **[go2rtc Integration](https://www.home-assistant.io/integrations/go2rtc/)** – Official HA integration docs
- **[HA 2024.11 Release Blog](https://www.home-assistant.io/blog/2024/11/06/release-202411/)** – Feature announcement; WebRTC details
- **[HA Core GitHub](https://github.com/home-assistant/core/blob/dev/homeassistant/components/camera/__init__.py)** – Source code; type definitions

### Tier 2 (High-Quality Community)
- **[Frigate Integration Issues](https://github.com/blakeblackshear/frigate-hass-integration/)** – Real-world WebRTC implementation (NVR use case)
- **[AlexxIT/WebRTC](https://github.com/AlexxIT/WebRTC)** – Custom WebRTC component; reference implementation for non-native WebRTC cameras

### Tier 3 (Reference)
- **[Frigate go2rtc Config Guide](https://docs.frigate.video/guides/configuring_go2rtc/)** – Codec support, transcoding options
- **[Community Discussions](https://github.com/home-assistant/architecture/discussions/)** – Design rationale; edge cases

---

## 7. Version-Specific Notes

- **2024.11+:** Native async WebRTC, go2rtc built-in
- **2025.6:** Deprecations finalize; `async_handle_web_rtc_offer` removed
- **2025+:** H.265 WebRTC support expanding (browser-dependent)
- **Future:** Potential multi-stream support per entity (currently single `stream_source`)

---

## 8. Gotchas & Best Practices

1. **Always set `supported_features`** – Missing `CameraEntityFeature.STREAM` breaks HLS fallback
2. **Don't block `camera_image()`** – Use `async_camera_image()` or executor jobs
3. **Track session_id carefully** – Each WebRTC connection has unique session; reuse for ICE candidates and close
4. **Handle offer/answer SDP correctly** – Cairn backend must return valid SDP answer; validate before sending to HA
5. **Ice candidate timing** – Don't send `close_webrtc_session()` until all candidates exchanged or stream closed
6. **Fallback gracefully** – If WebRTC unavailable, RTSP fallback should work seamlessly
7. **Codec mismatch:** If Cairn WebRTC uses H.265 and browser doesn't support, stream fails silently. RTSP fallback will transcode H.265 → H.264 (CPU cost)

