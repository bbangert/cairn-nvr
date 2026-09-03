# Cairn NVR — Claude Design Handoff

**Status**: RETURNED & IMPLEMENTED 2026-07-22 — the round-one Claude Design
export (`docs/design/cairn-nvr-prototype.zip`) has been recreated in the
LiveViews. This doc remains the functional-contract reference for the
round-one pages; attribute/id contracts will not change without updating
it. Later rounds are request specs under `docs/design/`:
`track-viewer-handoff.md` (Tracks, tracked-objects panel, bbox overlay) and
`camera-config-handoff.md` (Cameras, Add/Edit camera, zone editor, the
trimmed Config page).

**Round trip**: design the pages in Claude Design → export HEEx/HTML +
Tailwind classes back → we wire them into the existing LiveViews. Keep the
**functional contract** (element ids, `data-*` attributes, `phx-*`
bindings) exactly as specced; restyle everything else freely.

## Product in one paragraph

Cairn is an event-clip NVR (network video recorder) for a home LAN.
Cameras stream via RTSP; an in-VM detector finds objects (person, cat,
car…); Cairn records one mp4 clip per event (with pre-roll) and indexes it.
The UI is six live routes: a live **Dashboard** (`/`), an **Events**
browser (`/events`) with clip playback (`/events/:id`), a **Tracks** index
(`/tracks`), the **Cameras** pages (`/cameras`, `/cameras/new`,
`/cameras/:id/edit`, and `/cameras/:id/zones` once the zone editor
ships), and a **Config** page (`/config`; node settings read-only, with
Reload and Import again). No auth in v1 (LAN-trusted). Think "Frigate,
but event clips only" — utilitarian, glanceable at a distance (wall tablet), dark-mode-first
is a natural fit.

## Tech baseline

- Phoenix 1.8 LiveView, Tailwind CSS v4 + daisyUI (both already bundled).
- Layout wrapper: every page renders inside `<Layouts.app flash={@flash}>`.
- Icons: heroicons (`<.icon name="hero-...">` component available).
- Videos are `<video>` elements driven by JS hooks — the hook manages
  `src` (MSE) or `srcObject` (WebRTC); design must not set either or remove
  the `phx-*`/`data-*` attrs.
- LiveView re-renders server-side: interactive filtering/pagination is done
  with forms + `phx-change`/`phx-click` bindings, not client JS.

## Page 1 — Dashboard `/`

Camera grid; each camera is a tile. Empty state when no cameras configured.

**Functional contract per tile** (already implemented, keep intact):

```heex
<article id={"camera-tile-#{cam.id}"}>
  <h2>{cam.id}</h2>
  <span id={"camera-status-#{cam.id}"} data-status={status}>{status}</span>
  <video
    id={"camera-video-#{cam.id}-#{transport}"}
    phx-hook={if transport == :webrtc, do: "WebrtcPlayer", else: "MsePlayer"}
    phx-update="ignore"
    data-camera-id={cam.id}
    data-hls-url={"/hls/#{cam.id}/index.m3u8"}
    muted autoplay playsinline
  ></video>
</article>
```

The video id carries the transport (`-webrtc` / `-mse`) and the hook is
chosen server-side per camera (default `:webrtc`; flipped by the toggle or
by a `transport_failed` report). The suffix is load-bearing: under
`phx-update="ignore"` the id change is what makes LiveView replace the
element and swap the hook.

- `data-status` values to style: `connecting` (yellow/pulse), `running`
  (green), `backoff` (red — camera unreachable, retrying), `stalled`
  (orange), `transcode_unavailable` (red + needs message), `unknown` (gray).
  Status changes push live; design badge states for all six.
- **Live-event marker**: tile needs an "event in progress" affordance
  (e.g. red recording dot / border glow). Server assign: `@live_events` is
  a `%{camera_id => true}` map (subscribed to the `"events"` topic).
- **MSE ↔ WebRTC toggle** (Phase 7): per-tile toggle control, two states
  ("Low latency" WebRTC vs "Standard" MSE). Contract:
  `#camera-transport-{id}[data-transport]` holding two buttons
  `phx-click="toggle-transport" phx-value-camera={cam.id}
  phx-value-transport="mse|webrtc"`. The player hooks push three reports
  the hosting LiveView must handle — `webrtc_active {camera_id, width,
  height}`, `webrtc_inactive`, and (WebRTC only) `transport_failed`.
- **Disk alert banner**: page-level persistent banner when
  `@disk_alert.active` — "Low disk space: emergency cleanup is deleting
  oldest events" + free-space MB. Must be prominent but not block video.
- Grid should scale 1→9 cameras (1/2/3 columns responsive).

## Page 2 — Events `/events`

Filterable, paginated list of recorded event clips, newest first.

- **Filters** (form, `phx-change="filter"`): camera (`select name="camera"`,
  options from config), label (`select name="label"`, options from
  `Events.known_labels/0`), date range (`input type="date" name="from"` /
  `name="to"`). Empty option = "all".
- **List rows/cards** (LiveView streams: container needs
  `id="events-list" phx-update="stream"`, each child id comes from the
  stream): thumbnail (`event.snapshot_path` → `/media/snapshots/{event.id}`,
  fallback placeholder when nil), camera id, started_at (local time),
  duration (ended_at − started_at), label chips with max score
  (`event.labels["max_scores"]` map), status badge (`finalized` normal,
  `partial` warning "recording was interrupted").
- **Pagination**: `phx-click="page" phx-value-page={n}` prev/next + total
  count display.
- Empty state: "No events match" + clear-filters affordance.

## Page 3 — Event detail `/events/:id`

- `<video controls src={"/media/events/#{@event.id}"}>` — plain HTTP
  progressive playback with Range/seek support (implemented server-side).
  No hook needed. Poster: snapshot URL.
- Metadata panel: camera, start/end (local), duration, file size
  (`bytes`), max_score, status (+ `partial` explainer), event id (small,
  copyable).
- **Labels timeline**: `@event.labels["entries"]` is a list of
  `%{"t" => seconds_from_start, "label" => l, "score" => s,
  "object_id" => n}`. Design a horizontal timeline (x = t within clip
  duration) with per-label rows or colored markers; clicking a marker
  seeks the video (`phx-click` optional — a plain JS-free design using
  anchors is fine; we'll wire seeking with a tiny hook:
  `data-seek={t}` on marker elements, hook name `TimelineSeek`).
- Back-link to `/events` preserving filters (`patch` navigation).

## Page 4 — Config `/config`

The node settings render read-only from the YAML file, but the page is not:
it carries Reload and the destructive "Import again", which replaces every
camera row with the file's. Cameras are no longer shown here: they live in
the database and are managed on `/cameras` (see
`docs/design/camera-config-handoff.md`,
which also specifies this page's import section and the link row that
replaced the camera cards).

- Sections: globals (data_dir, windows, retention, thresholds), config
  health, then a link row to Cameras.
- **Reload button**: `phx-click="reload"`. It re-reads the file's globals
  and the database's cameras together. Result states to design:
  - success: diff summary (added/removed/restarted/updated camera id
    chips) + warnings list (yellow)
  - failure: error list (red) + "previous config still active" notice
- Last-load warnings/errors shown persistently under a "Config health"
  heading (assigns: `@last_load.warnings`, `@last_load.errors`).

## Shared / global

- Nav: five items (Dashboard, Events, Tracks, Cameras, Config) + app name
  "Cairn". Current page indicator. Keep it minimal; no user menu (no
  auth).
- Flash messages: standard LiveView flash (`Layouts.app` renders them).
- Empty/loading states for every async panel.
- Timestamps: render in browser-local time (`<time datetime={iso}>`; we
  format server-side, design just styles).
- Density: this is an operations tool — favor information density over
  whitespace, but keep tap targets tablet-friendly.

## Data shapes (for realistic mock content)

```jsonc
// Event (runtime + index row union, JSON-stable)
{
  "id": "b2c9…uuid", "camera_id": "front_door",
  "started_at": "2026-07-22T18:03:11.201Z",
  "ended_at": "2026-07-22T18:04:02.913Z",
  "status": "finalized",            // active | finalized | partial
  "bytes": 14380211, "max_score": 0.93,
  "snapshot_path": "…/snapshots/b2c9.jpg",
  "labels": {
    "max_scores": {"person": 0.93, "cat": 0.61},
    "entries": [{"t": 0.4, "label": "person", "score": 0.91, "object_id": 1}]
  }
}
// Camera status map entry
{"status": "running", "probe": {"codec": "h264", "width": 2560,
  "height": 1440, "fps": 20.0, "profile": "Main"}}
```

## What gates on this handoff

Backend work proceeds regardless; the following are **blocked on the
design export coming back**: final dashboard tile/badge styling, events
list/detail visual design, labels timeline component, config page layout,
nav/layout chrome. Functional scaffolds for all of these exist so the app
stays demoable in the meantime.
