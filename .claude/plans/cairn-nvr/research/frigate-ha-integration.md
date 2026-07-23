# Frigate Home Assistant Integration: Architecture & Prior Art

**Research Date:** July 2026  
**Focus:** Integration architecture, entity model, MQTT protocol, streaming, and pain points for designing Cairn (Elixir-based NVR)

---

## 1. Custom Component Architecture: frigate-hass-integration

### Entity & Device Model [T1]

The **frigate-hass-integration** (hosted at [github.com/blakeblackshear/frigate-hass-integration](https://github.com/blakeblackshear/frigate-hass-integration)) is a HACS-distributed custom component that creates the following entity types:

- **Cameras**: Live streams via RTSP port (default 8554); also object-detected snapshots
- **Sensors**: Camera FPS, detection FPS, process FPS, skipped FPS, object counts per detection label
- **Binary Sensors**: Motion detection per camera/zone/object
- **Switches**: Toggles for recording, detection, snapshots, and contrast improvement on cameras
- **Services**: Manual event creation, PTZ camera control
- **Image Entities**: Latest detected object snapshots

No explicit "event entity" type is created; events are published via **MQTT topics** (`frigate/events` and `frigate/reviews`) instead, which Home Assistant automations consume directly.

### Discovery & Installation [T1, T2]

**Not automatic discovery.** Instead:

1. Install via HACS as a default repository
2. Restart Home Assistant
3. Manually add via Settings > Devices & Services > Create Integration

This two-step install pattern creates operational friction, especially in distributed setups (separate Frigate and HA containers/VMs).

### Integration Status: HACS-Only [T1]

As of 2026, **frigate-hass-integration is not in Home Assistant core**; it remains HACS-only. The latest release is **v5.15.4 (June 2026)**, with 1.2k stars on GitHub, indicating active maintenance and community adoption.

---

## 2. MQTT Layer: The Critical Dependency

### MQTT Requirement [T1, T2]

**The integration is entirely MQTT-driven, not HTTP polling.** The core architectural requirement:

> "The mqtt integration must be installed and configured in order for the Frigate integration to work." [T1]

This creates a hard dependency on an MQTT broker (typically Mosquitto in Home Assistant). Frigate must:
- Connect to the same MQTT server as Home Assistant
- Publish event, status, and metric payloads continuously
- Maintain connection; loss of MQTT breaks entity availability

### MQTT Topic Hierarchy & Payloads [T1, T3]

**Primary Topics:**

| Topic | Purpose | Payload Type |
|-------|---------|--------------|
| `frigate/events` | Object detection events (entry/update/exit) | Change feed (before/after) |
| `frigate/reviews` | **Recommended for notifications** | Event summary with media refs |
| `frigate/{camera}/stats` | Performance metrics (FPS, CPU usage) | JSON counters |
| `frigate/{camera}/audio/{audio_type}` | Audio event notifications | Limited payload (no snapshots) |
| `frigate/{camera}/motion` | Motion/zone detection state | Binary (on/off) |
| `frigate/{camera}/availability` | MQTT connection heartbeat | `online`/`offline` |

**Event JSON Structure (Change Feed Format):**

```json
{
  "before": {
    "id": "event-uuid",
    "camera": "front_door",
    "label": "person",
    "start_time": 1626374400,
    "snapshot": {
      "frame_time": 1626374405.123,
      "box": { "top": 100, "left": 50, "width": 200, "height": 300 },
      "area": 60000,
      "region": [ [50, 100], [250, 100], [250, 400], [50, 400] ],
      "score": 0.95
    },
    "has_snapshot": true,
    "has_clip": true,
    "entered_zones": [],
    "attributes": { "person_name": null }
  },
  "after": {
    "id": "event-uuid",
    "camera": "front_door",
    "label": "person",
    "start_time": 1626374400,
    "end_time": 1626374415,
    "entered_zones": ["driveway"],
    "has_snapshot": true,
    "has_clip": true,
    "snapshot": { "...": "updated frame" }
  },
  "type": "update"  // or "new", "end"
}
```

### Event Lifecycle [T3]

Events flow as `new` → `update` (zero or more) → `end`. The `frigate/reviews` topic aggregates multiple detections into a single notification payload with a `thumb_path` field, reducing notification spam compared to raw `frigate/events` topic.

### HTTP API Complementarity [T1]

While MQTT powers state/event streaming, Frigate exposes HTTP endpoints for:
- Thumbnail/snapshot fetches: `GET /api/frigate/notifications/{event_id}/thumbnail.jpg`
- Clip retrieval
- PTZ commands
- Availability probe

These allow HA to fetch media **without exposing Frigate's full API surface** to the web—a key privacy advantage over direct HTTP polling.

---

## 3. Live Streaming Architecture: go2rtc

### go2rtc's Role [T1]

**go2rtc** is an optional (but widely recommended) bundled component providing WebRTC and MSE (Media Source Extensions) streaming, bypassing Frigate's basic jsmpeg stream (detect resolution, no audio).

### Streaming Protocol Comparison [T1]

| Protocol | Latency | Audio | Network | Use Case |
|----------|---------|-------|---------|----------|
| **WebRTC** | <200ms (near-realtime) | 2-way talk | Requires P2P negotiation; NAT-sensitive | Live monitoring, PTZ control |
| **MSE (HLS variant)** | 500ms-1s | One-way AAC/PCMU/PCMA | TCP-only, works through proxies | Dashboard live view (default) |
| **jsmpeg** | ~200ms | No | Low bandwidth | Fallback; detect-resolution only |

**Port Requirements:**
- WebRTC: UDP/TCP 8555 (peer connections)
- MSE: TCP 8971 (via Frigate API)
- go2rtc web UI: TCP 1984 (disabled by default in HA to prevent external access)

### Codec Constraints [T1]

Audio support is strictly codec-gated:
- **MSE**: AAC, PCMA, PCMU only
- **WebRTC**: Opus, PCMA, PCMU only

Many cameras default to codecs outside these sets, requiring ffmpeg transcoding (adds latency) or failing silently (audio missing from UI).

### Latency in Practice [T1]

While specific figures aren't documented in official guides, experienced users report:
- WebRTC: <200ms (nearly imperceptible for live viewing)
- MSE: 500ms–1s (acceptable for dashboard, problematic for PTZ response feedback)
- go2rtc transcoding: Additional 100–500ms depending on camera & system load

---

## 4. Media Browser & media_source Integration [T1]

### Enabled via media_source [T1]

The HA media browser integration requires `media_source:` in Home Assistant's configuration. Once enabled:
- **Tracked object recordings** appear with thumbnails organized by detection label
- **Monthly/daily folder structure** for browsing past events
- **Snapshot browser** with navigation by camera and time range
- **Clip playback** with frame-accurate seeking

### URL Endpoints for UI [T1]

Media fetches use authenticated HA API paths:
```
https://your.ha.instance/api/frigate/notifications/{event_id}/thumbnail.jpg?format=android
https://your.ha.instance/api/frigate/notifications/{event_id}/clip.mp4
```

Format parameter allows device-specific optimization (Android, iOS, web).

### Rich Media Browser Card [T1]

A dedicated Lovelace card is available for enhanced UI with thumbnails, event timelines, and drill-down to specific detections, making forensic review accessible without leaving HA.

---

## 5. Notifications: The Popular Blueprint Pattern [T1, T2, T3]

### Recommended Approach [T1]

Official guidance: **"The best way to get started with notifications for Frigate is to use the Blueprint."**

Official blueprint available in Home Assistant community forum; users customize YAML for their workflow.

### frigate/reviews Topic for Notifications [T1]

Recommended over `frigate/events` for notification triggers because:
- Aggregates multiple detections into a single alert
- Includes `thumb_path` pointing to review thumbnail
- Reduces notification spam (events can fire 10s of times per incident)

### Customizable Event Data [T1]

Blueprints access:
- `label`: Detection class (person, car, dog, etc.)
- `id`: Event UUID (tied to snapshot/clip lifecycle)
- `start_time`: Timestamp (milliseconds, UNIX)
- `camera`: Source camera name
- `severity`: Alert level (if configured in Frigate)
- `data.objects`: Full detection array with confidence scores
- iOS-specific: `entity_id` enables live camera preview in notification

### Community Blueprints [T2, T3]

Popular variants:
- **sam2kb/frigate-ai-notification-blueprint**: Multi-camera with LLM vision option, low-noise filtering
- **HA Blueprint Hub Frigate Notifications**: Supports suppression windows, notification deduping by event ID
- Simplepush integration examples for external alerting

### Notification Deduping Strategy [T3]

Uses MQTT `frigate/reviews` event ID as tag; iOS/Android HA app treats same tag as notification replacement (not duplicate). Allows configurable suppression windows (e.g., mute repeated person detections for 30s).

---

## 6. Community Pain Points & Operational Friction [T2, T3]

### MQTT Broker Dependency [T3]

**Most cited pain point:** Frigate requires an MQTT broker to work with HA integration, adding operational complexity:
- Requires Mosquitto add-on or external broker
- Networking between containers/VMs must support MQTT
- Firewall rules, DNS resolution, credentials all add friction
- Broken MQTT = unavailable Frigate entities (no graceful degradation)

Community reports (from forum threads):
- "Cannot subscribe to topic 'frigate/…', make sure MQTT is set up correctly"
- "client is not connected" / "Unable to publish" errors
- Frigate crashes when MQTT enabled on remote machine in Docker

### Two-Step Installation & Configuration Drift [T3]

- Install via HACS (add repository, restart HA)
- Manually add integration (Settings > Integrations)
- Frigate config must enable MQTT separately
- HA MQTT integration must be configured separately
- Easy to get partial setup (entities available but unavailable)

### Unavailable Entities [T3]

Recurring community issue: Entities appear in HA but stuck `unavailable`. Root causes:
- MQTT connection lost or broker unreachable
- Frigate not publishing to expected topics
- Entity discovery payload malformed
- No clear error messages to diagnose MQTT path failures

### Live Video Access & Network Complexity [T1, T2]

- WebRTC requires port 8555 UDP/TCP to be reachable (NAT/firewall friction for remote access)
- MSE is more firewall-friendly but adds 500ms–1s latency
- RTSP restream (port 8554) adds another reachable port requirement
- Codec negotiation is silent; audio often fails without explanation

---

## Design Lessons for Cairn (Elixir NVR)

### Architectural Insights

1. **MQTT as Event Bus**: Frigate's decision to use MQTT for all state/events is sound for home automation (fits HA's event-driven model), but creates a hard operational dependency. Consider HTTP webhooks as a first-class alternative to reduce broker requirement.

2. **Entity Model**: The entity split (camera, sensor, binary_sensor, switch, service) is idiomatic to HA's platform model. Cairn should expose entities via integration, not expect users to parse raw MQTT.

3. **Streaming Complexity**: go2rtc is delegated; Frigate itself doesn't handle WebRTC negotiation. For Cairn, consider embedding or tightly integrating a streaming codec negotiator to avoid silent audio failures.

4. **Media Lifecycle**: Events (new/update/end) with async snapshot/clip generation is the pattern. Cairn should publish event **IDs** immediately, fetch media async, publish media-ready notifications separately.

5. **Notification Deduping**: Event ID tagging is powerful; avoid per-detection notifications if events aggregate multiple detections (causes alert fatigue).

6. **Installation UX**: The two-step (HACS + manual integration) install is friction. Cairn's HA integration should auto-discover via manifest if possible, or provide a one-click install flow.

### Pain Points to Avoid

- Don't require an external broker; offer HTTP webhooks as primary transport
- Graceful degradation when HA unreachable (local event logging, retry queues)
- Clear error messages for config issues (connectivity, auth, topic mismatch)
- Pre-negotiate codecs; fail fast on codec unsupported by player

---

## Sources

### Authoritative (T1)

- [Frigate Home Assistant Integration Docs](https://docs.frigate.video/integrations/home-assistant/)
- [frigate-hass-integration GitHub Repository](https://github.com/blakeblackshear/frigate-hass-integration)
- [Configuring go2rtc Guide](https://docs.frigate.video/guides/configuring_go2rtc/)
- [Frigate Home Assistant Notifications Guide](https://docs.frigate.video/guides/ha_notifications/)
- [Frigate Live View Configuration](https://docs.frigate.video/configuration/live/)

### First-Party Discussions (T2)

- [Frigate GitHub Discussions: How to integrate when each on own server (#12057)](https://github.com/blakeblackshear/frigate/discussions/12057)
- [Frigate GitHub Discussions: Enable Frigate HASS integration with MQTT (#12851)](https://github.com/blakeblackshear/frigate/discussions/12851)
- [Frigate GitHub Issues: Event ID in audio events MQTT payload (#8862)](https://github.com/blakeblackshear/frigate/issues/8862)

### Community (T3)

- [HA Community Forum: Overview entities unavailable from frigate](https://community.home-assistant.io/t/overview-entities-unavailable-from-frigate/661939)
- [HA Community Forum: Cannot get Frigate Devices working due to MQTT Error](https://community.home-assistant.io/t/cannot-get-frigate-devices-working-using-integration-due-to-mqtt-error/757865)
- [HA Community Forum: Frigate Mobile App Notifications Blueprint Exchange](https://community.home-assistant.io/t/frigate-mobile-app-notifications/311091)
- [GitHub: sam2kb/frigate-ai-notification-blueprint](https://github.com/sam2kb/frigate-ai-notification-blueprint)
- [Frigate GitHub Discussions: Sharing notification blueprints (#14616)](https://github.com/blakeblackshear/frigate/discussions/14616)
