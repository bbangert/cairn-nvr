# Home Assistant Integration Options for Cairn NVR (2026)

## Executive Summary

Cairn—an Elixir-based event-recording NVR—can reach Home Assistant users via three realistic v1 paths, each with distinct capability/complexity tradeoffs. **MQTT + Discovery** is lowest effort but limits to snapshots and basic events; **Custom Integration (HACS → Core)** requires Python but unlocks live streaming, clip browsing, and OOB ease; **ONVIF exposure** is viable but narrow in scope. Analysis below covers discovered integration strategies across the ecosystem.

---

## 1. MQTT Discovery + Broker Path

### Capability Ceiling

MQTT discovery in HA 2026 supports three entity types relevant to NVR:
- **`event`** entities: Momentary signals (motion detected, object alert). Payload includes `event_type` + optional attributes. Good for alerting but stateless.
- **`camera` (MQTT image)**: Static image updates only. Receives JPEG/PNG over MQTT topic; no live streaming support (HLS/WebRTC not available via MQTT camera).
- **`image` entities**: Similar to camera, for snapshot display in dashboards.

Event entities alone cannot trigger automations on detection events; HA requires a broker message → MQTT discovery → event entity → automation trigger pipeline.

### Broker Requirement

Users must run MQTT broker (Mosquitto add-on, external, or embedded). Frigate's HA integration mandates this; it is the integration pattern ecosystem has standardized on.

### Pros
- **Lowest effort**: No Python. Cairn publishes JSON to MQTT topics; HA auto-discovers via MQTT device registry.
- **Minimal HA footprint**: No custom code to maintain in HA core/HACS; Cairn owns publisher logic.
- **Battle-tested**: Frigate, Z2M, ESPHome all use MQTT discovery; community expertise abundant.

### Cons
- **No live video**: MQTT camera is snapshot-only. Users cannot watch live WebRTC/HLS stream in HA.
- **No clip browsing**: No media_source support; users must access clip archive outside HA (web UI, NAS).
- **UX friction**: Requires separate MQTT broker installation/config; adds LAN infrastructure.

---

## 2. Custom Integration (HACS → HA Core)

### Capability Ceiling

Custom integrations can expose:
- **Camera entities** with `stream_source()`: Return RTSP/HLS URL → HA Stream component converts to HLS for frontend. Native WebRTC support via `async_handle_async_webrtc_offer()` if Cairn exposes go2rtc endpoint.
- **media_source platform**: Browse event clips hierarchically in Media Browser UI (e.g., `clips/2026-07-22/person-detection/`); play/download via media players.
- **Device registry**: Full zeroconf/mDNS auto-discovery ("Discovered: Cairn") + device grouping.
- **Custom services**: Trigger recording, snapshot, reboot, etc.
- **Event entities**: Via config flow, not just MQTT discovery.
- **Binary sensors**: Motion, person, vehicle, etc.

### Development Path

1. **HACS only**: Distribute via GitHub repo + HACS registry (weeks to months of community use; low approval burden).
2. **Core submission**: Requires Python library (pypi package) + meets [HA integration bronze quality scale](https://developers.home-assistant.io/docs/core/integration/contributing_to_core/):
   - Established product (Cairn must be real, not pre-beta).
   - Well-scoped PR (camera entity + basic events, not all features upfront).
   - CI/linting pass.
   - Review timeline: Opaque in HA docs, but community reports 2–12 weeks for review, multiple feedback rounds.

### Non-Python Caveat

Elixir team unlikely to write Python. Workaround: **Create a minimal Python wrapper library** (cairn-py) that wraps HTTP API (POST/GET to Cairn's Elixir endpoints). Outsource integration authorship to community volunteer or hire contractor. HA core maintains integration; Cairn team maintains HTTP API stability.

### Pros
- **OOB UX**: Auto-discovery + full camera + clips browsing = user installs Cairn, add integration, sees live streams & clips immediately.
- **Live video**: Streams via camera entity (HLS or WebRTC). Critical differentiator vs. MQTT.
- **Media discovery**: Browse clips by date, event type, etc. without leaving HA.
- **Wider appeal**: Mirrors Reolink, UniFi Protect, Frigate's approach—users expect this.
- **Long-term credibility**: Core integration signals production-readiness.

### Cons
- **Python dependency**: Requires external dev or learning curve.
- **Maintenance burden**: HA core pull requests tie Cairn to HA's release cycle (2-week sprints, potential breaking API changes).
- **Review uncertainty**: First PR may be rejected; resubmission adds months.
- **HACS middleman**: Some users distrust non-core integrations; HACS adoption is still < core.

---

## 3. ONVIF Profile T/M Event Exposure

### Capability Ceiling

HA's ONVIF integration auto-discovers Profile S/T cameras via WS-Discovery, exposes:
- Live RTSP stream (converted to HLS by Stream component).
- Motion & event sensors (tampering, line crossing, intrusion, human/vehicle detection).
- PTZ controls (if camera supports it).

**Cairn could expose ONVIF Profile T**:
- RTSP stream endpoint (already available for cameras).
- ONVIF event service (motion, object detection events).
- Auto-discovery via WS-Discovery broadcast on LAN.

### Pros
- **Zero HA integration code**: ONVIF integration already in HA core; no Python needed.
- **OOB discovery**: WS-Discovery is automatic; user adds IP.
- **Mature protocol**: ONVIF is industry standard; other devices already interop.
- **Event support**: ONVIF Profile T supports detection events.

### Cons
- **Narrow scope**: ONVIF is camera-first protocol; NVR role is unconventional.
- **No clip browsing**: ONVIF has no media archive standard; clips remain outside HA.
- **Limited event richness**: ONVIF supports basic events; proprietary detection metadata (model version, confidence, etc.) not surfaced.
- **Overhead**: ONVIF implementation adds significant complexity to Cairn (SOAP services, WS-Discovery).
- **Not standard**: No known NVR exposes ONVIF for event discovery (Reolink, UniFi do not).

---

## 4. Webhook Triggers

HA webhook integration is **trigger-only**: Cairn sends HTTP POST to `http://ha:8123/api/webhook/{webhook_id}` with event JSON. Users create automation `on_webhook_trigger`. **No entity exposure** (no camera, sensor, or clip browsing). Unsuitable as primary integration path, suitable only as supplement to media_source.

---

## 5. Zeroconf/mDNS Discovery

HA zeroconf integration auto-discovers services advertising `_http._tcp` (or custom service type) via mDNS. If Cairn broadcasts `_cairn-nvr._tcp`, HA can surface "Discovered: Cairn" in integrations UI → user clicks → config flow captures IP/auth → integration loads.

**Requirement**: Cairn broadcasts mDNS service with TXT records (hostname, port, API version). Python library/custom integration can implement discovery handler.

**Benefit**: Users never type IP; discovered automatically. Standard for HACS integrations (ESPHome, etc.).

---

## Ecosystem Precedents (2025–2026)

| Product | HA Integration | Method | Clip Browsing | Live Video | Discovery |
|---------|---|---|---|---|---|
| **Frigate** | HACS + core | MQTT + native entities | ✓ (media_source) | ✓ (camera entity, HLS) | Config + IP |
| **Reolink** | Core | Native Python lib | ✗ | ✓ (camera, RTSP) | Config + IP |
| **UniFi Protect** | Core | Native Python lib | ✗ | ✓ (camera, RTSP) | Config + API key |
| **Scrypted** | Add-on + webhooks | Separate platform | ✓ (media_source) | ✓ (WebRTC) | Config + IP |

**OOB Winner**: Frigate. Native integration + media_source + MQTT events. No proprietary protocol; users already run Mosquitto.

---

## Synthesis: Three Realistic v1 Paths

### Path A: MQTT-Only (Minimum Viable)

**Thesis**: Ship v1 fast, prove value with events & snapshots, iterate to streaming later.

- Cairn publishes motion, object detect, snapshots to MQTT topics.
- Users install Mosquitto add-on, run discovery broker, auto-configure Cairn IP.
- HA displays event history in event entity + snapshot image.
- No media_source or live video in v1.

**Antithesis**: Users expect live video (Frigate, Reolink, UniFi all have it). Snapshot-only NVR in 2026 feels incomplete. Competitors all expose live streams; Cairn appears limited. MQTT broker friction for non-technical users. Likely adoption plateau.

**Effort**: 2–3 weeks (MQTT publisher in Cairn, minimal docs). **Maintenance**: Low (Cairn owns logic).

---

### Path B: Custom Integration (HACS + Media Source) → Core

**Thesis**: Build "Frigate-class" experience: auto-discover, live streams, clip browsing, then pursue core inclusion for credibility.

- Write minimal Python library (cairn-py) wrapping Cairn's HTTP API.
- Distribute custom integration via HACS (zeroconf auto-discovery + config flow).
- Expose camera entity (RTSP/HLS) + media_source (clip browser) + event entities.
- Test for 2–3 months in community, refine UX.
- Submit to HA core (expects 2–12 weeks review, may require iteration).

**Antithesis**: Python adoption risk if Elixir team resists. Core submission is high-stakes; first PR may fail, demoralizing. Community integration maintenance burden (issues, PRs, HA API changes). Requires hiring contractor or community volunteer if Elixir team unavailable.

**Effort**: 4–8 weeks (Python lib + HA config flow + media_source). **Maintenance**: Medium (HA API churn, community support).

---

### Path C: Hybrid (MQTT Events + ONVIF Streams)

**Thesis**: Separate concerns—Cairn as NVR publishes events via MQTT, streams via ONVIF. HA discovers ONVIF naturally; no integration needed for camera. Events come via MQTT (low friction).

- Cairn exposes RTSP + ONVIF Profile T (WS-Discovery + event service).
- HA ONVIF integration auto-discovers Cairn, streams live video, exposes motion binary sensor.
- Cairn publishes detailed detection events (person, vehicle, etc.) to MQTT topics → custom broker automation.
- No HA-specific Python; leverages standard protocols.

**Antithesis**: ONVIF is overkill for NVR (camera-centric protocol). Adds significant complexity to Cairn (SOAP, WS-Discovery, event schema mapping). No clip browsing; media discovery remains outside HA. Community has not done this; risk of incompatibility. Fewer users familiar with ONVIF than MQTT/REST.

**Effort**: 6–10 weeks (ONVIF Profile T implementation in Cairn; no HA code). **Maintenance**: Moderate (ONVIF spec compliance, WS-Discovery debugging).

---

## Recommendation (No Winner)

**For small Elixir team with realistic timeline**:

1. **Path A (MQTT)** is fastest to revenue/proof; suitable if clip browsing is non-essential v1 feature.
2. **Path B (Custom Integration)** is highest UX ceiling and aligns with market (Frigate, etc.), but requires Python external hire or community buy-in.
3. **Path C (ONVIF)** is technically pure but overengineered; minimal market validation; reserves ONVIF for future if Cairn expands to IP camera line.

**Honest pick**: **Path B** if budget allows contractor; **Path A** if time-to-market critical and live streaming can wait. Avoid Path C unless Cairn commits to long-term ONVIF ecosystem play.

---

## Sources

- [HA MQTT Event Entity](https://www.home-assistant.io/integrations/event.mqtt/) [T1]
- [HA MQTT Camera](https://www.home-assistant.io/integrations/camera.mqtt/) [T1]
- [HA MQTT Image](https://www.home-assistant.io/integrations/image.mqtt/) [T1]
- [HA Core Integration Submission Requirements](https://developers.home-assistant.io/docs/core/integration/contributing_to_core/) [T1]
- [HA Camera Entity](https://developers.home-assistant.io/docs/core/entity/camera/) [T1]
- [HA Media Source Platform](https://developers.home-assistant.io/docs/core/platform/media_source/) [T1]
- [HA Zeroconf Integration](https://www.home-assistant.io/integrations/zeroconf/) [T1]
- [HA ONVIF Integration](https://www.home-assistant.io/integrations/onvif/) [T1]
- [Frigate HA Integration Docs](https://docs.frigate.video/integrations/home-assistant/) [T1]
- [Frigate HA Integration GitHub](https://github.com/blakeblackshear/frigate-hass-integration) [T1]
- [Reolink HA Integration](https://www.home-assistant.io/integrations/reolink/) [T1]
- [UniFi Protect HA Integration](https://www.home-assistant.io/integrations/unifiprotect/) [T1]
- [WebRTC Custom Component (AlexxIT)](https://github.com/AlexxIT/WebRTC) [T3]
- [HA Integration Quality Scale & HACS](https://community.home-assistant.io/t/help-needed-to-submit-my-integration/1010408) [T3]
- [HACS 2.0](https://www.home-assistant.io/blog/2024/08/21/hacs-the-best-way-to-share-community-made-projects/) [T2]
