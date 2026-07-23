# Cairn NVR — Claude Design Handoff

**Status**: RETURNED & IMPLEMENTED 2026-07-22 — the Claude Design export (docs/design/cairn-nvr-prototype.zip) has been recreated in the LiveViews. This doc remains the functional-contract reference.
implemented (Phases 1–5) or frozen (Phase 6–7 endpoints); attribute/id
contracts will not change without updating this doc.

**Round trip**: design the pages in Claude Design → export HEEx/HTML +
Tailwind classes back → we wire them into the existing LiveViews. Keep the
**functional contract** (element ids, `data-*` attributes, `phx-*`
bindings) exactly as specced; restyle everything else freely.

## Product in one paragraph

Cairn is an event-clip NVR (network video recorder) for a home LAN.
Cameras stream via RTSP; an AI plugin detects objects (person, cat, car…);
Cairn records one mp4 clip per event (with pre-roll) and indexes it.
The UI is three pages: a live **Dashboard**, an **Events** browser with
clip playback, and a read-only **Config** page. No auth in v1 (LAN-trusted).
Think "Frigate, but event clips only" — utilitarian, glanceable at a
distance (wall tablet), dark-mode-first is a natural fit.

## Tech baseline

- Phoenix 1.8 LiveView, Tailwind CSS v4 + daisyUI (both already bundled).
- Layout wrapper: every page renders inside `<Layouts.app flash={@flash}>`.
- Icons: heroicons (`<.icon name="hero-...">` component available).
- Videos are `<video>` elements driven by JS hooks — the hook manages
  `src`; design must not set `src` or remove the `phx-*`/`data-*` attrs.
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
    id={"camera-video-#{cam.id}"}
    phx-hook="MsePlayer"
    phx-update="ignore"
    data-camera-id={cam.id}
    data-hls-url={"/hls/#{cam.id}/index.m3u8"}
    muted autoplay playsinline
  ></video>
</article>
```

- `data-status` values to style: `connecting` (yellow/pulse), `running`
  (green), `backoff` (red — camera unreachable, retrying), `stalled`
  (orange), `transcode_unavailable` (red + needs message), `unknown` (gray).
  Status changes push live; design badge states for all six.
- **Live-event marker**: tile needs an "event in progress" affordance
  (e.g. red recording dot / border glow). Server assign: `@live_events` is
  a `%{camera_id => true}` map (subscribed to the `"events"` topic).
- **MSE ↔ WebRTC toggle** (Phase 7): per-tile toggle control, two states
  ("Low latency" WebRTC vs "Standard" MSE). Contract: button with
  `phx-click="toggle-transport"` `phx-value-camera={cam.id}`.
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

Read-only render of the active YAML config + reload workflow.

- Sections: globals (data_dir, windows, retention, UDP range, thresholds),
  then per-camera cards: id, rtsp_url (mask password part —
  server sends it pre-masked), plugin command, min_score map, windows,
  retention, `transcode` flag.
- **Per-camera probe results** (Phase 8): codec, resolution, fps, profile
  + warning states: non-H.264 camera → warning chip "switch camera to
  H.264 or enable transcode"; `transcode_unavailable` → error chip.
- **Reload button**: `phx-click="reload"`. Result states to design:
  - success: diff summary (added/removed/changed camera id chips) +
    warnings list (yellow)
  - failure: error list (red) + "previous config still active" notice
- Last-load warnings/errors shown persistently under a "Config health"
  heading (assigns: `@last_load.warnings`, `@last_load.errors`).

## Shared / global

- Nav: three items (Dashboard, Events, Config) + app name "Cairn". Current
  page indicator. Keep it minimal; no user menu (no auth).
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
