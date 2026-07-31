# Handoff request: Cairn NVR — Track viewer (Tracks browse, tracked-objects panel, bbox overlay)

## Overview
This is a **request spec** for a second design round on Cairn, the event-clip
NVR you already prototyped (Dashboard / Events / Event detail / Config). One
new page and two additions to an existing page:

1. **Tracks (`/tracks`)** — a browse page over the *track index*: one row per
   tracked object the system ever saw, whether or not it was recorded. Text
   rows, no thumbnails. Filter bar + pagination in the Events-page pattern.
2. **Event detail (`/events/:id`) — tracked-objects side panel**: per-object
   rows with an expandable list of that object's transitions; clicking a
   transition seeks the clip when its moment is in *this* clip, and
   navigates to the clip that has it when it is not. A long-lived track
   spans multiple clips — a car that arrives (clip 1), parks for hours
   (nothing recorded), and leaves (clip 2) — and its transitions list is
   how the clips cross-link.
3. **Event detail — bbox overlay**: a `<canvas>` layered over the existing
   `<video controls>`, drawing the selected objects' boxes as the clip plays.

Everything from the first round stands. Same dark-only theme, same topbar, same
tokens, same primitives — **do not restate or re-derive the token sheet**; you
have `hs/colors_and_type.css` and `hs/shared.css` and they carry over
unchanged. Describe only what is new, and say which existing primitive each new
element is built from.

## What we need back
Same bundle shape as last time: prototype HTML for the new page and the changed
Event-detail view, plus any additions to `hs/shared.css` (only if a genuinely
new primitive is required — first try to compose from the existing ones). Reuse
`image-slot.js` placeholders for the video area; it stays prototype-only.

Production is Phoenix 1.8 LiveView; the prototype is a visual reference, not
code to port. **The functional contract below is the exception** — those
attributes are load-bearing and get copied verbatim into production markup.

## Fidelity
**High-fidelity**, matching round one. New surfaces must be indistinguishable
in weight, spacing, and color from the pages already built.

## Functional contract (must be kept verbatim)
Existing contracts from round one are unchanged (`phx-change="filter"`,
`phx-click="page" phx-value-page={n}`, `<time datetime={iso}>`, timeline
markers `data-seek` under the `TimelineSeek` hook, `<video controls
src={"/media/events/#{@event.id}"}>` with no hook). **New entries:**

- **Overlay** — hook container wrapping the canvas, canvas ignored by LiveView:
  ```heex
  <div
    id="track-overlay-wrap"
    phx-hook="TrackOverlay"
    data-video-id="event-clip"
    data-sidecar-url={~p"/media/events/#{@event.id}/tracks"}
    data-event-seconds={clip_seconds(@event)}
  >
    <canvas id="track-overlay" phx-update="ignore"></canvas>
  </div>
  ```
  The canvas must sit exactly over the `<video id="event-clip">` box, be
  `pointer-events: none` (native video controls stay clickable), and be free to
  letterbox: the hook maps normalized boxes through
  `videoWidth`/`videoHeight` vs. the element's rect, so the canvas fills the
  element and the JS handles the bars. Never set canvas `width`/`height` in
  CSS-only terms — the hook owns the backing store (DPR-scaled) and the
  `ResizeObserver`.
- **Per-object toggle** — `phx-click="toggle-track" phx-value-id={object_id}`
  on the object row (or its visibility control). Selected/unselected is server
  state; the overlay draws only selected objects.
- **Transition rows** — three functional variants, decided by where the
  moment falls:
  - *In this clip*: a `<button>` carrying `data-t={t}` (seconds since event
    start), living **inside the `TimelineSeek`-hooked region** (either the
    existing `#labels-timeline` section or a second element with
    `phx-hook="TimelineSeek"` and its own `data-video-id` /
    `data-event-seconds`). That hook rewrites `data-t` into a
    pre-roll-corrected `data-seek` on `loadedmetadata` — a seek row outside
    it seeks to the wrong place.
  - *In another clip*: a plain navigation link (`<.link navigate=...>`) to
    `~p"/events/#{other_event_id}?track=#{object_id}&t=#{seconds}"` — same
    object pre-selected there, seeked once metadata loads. Not a `data-t`
    button.
  - *Not recorded*: inert, no interactive element.
- **Event-page URL params** — `?track={object_id}` pre-selects the object;
  `?t={seconds}` seeks after `loadedmetadata` (same pre-roll correction).
  Both are part of the contract; cross-clip links depend on them.
- **Per-object color assignment** — every object gets one color, used
  identically by its row marker/chip and by its box on the canvas. The
  assignment rule is an open question (below); whatever you pick, the row and
  the canvas must be able to derive it from the same input.
- **Tracks page** — filters form `phx-change="filter"` with
  `select name="camera"`, `select name="label"`, `select name="zone"`,
  `input type="date" name="from"/"to"` (empty option = all); rows in
  `id="tracks-list"`; pagination `phx-click="page" phx-value-page={n}`;
  row link target `~p"/events/#{event_id}?track=#{object_id}"`.

## Design tokens & reuse
No new tokens unless something below genuinely has no home. Build from:

- `.hs-card`, `.hs-badge` / `--warning` / `--success`, `.hs-dot`, `.hs-field`,
  `.hs-input`, `.hs-btn` / `--secondary` / `--ghost` / `--sm` / `--icon`,
  `.label-chip`, `.tnum`, `.ms`, `.cairn-event-row`, `cairn-pulse`.
- `--hs-fg-1…4`, `--hs-bg-surface` / `--hs-bg-sunken` / `--hs-bg-raised`,
  `--hs-border-2`, `--hs-accent` / `--hs-accent-soft`, `--hs-success`,
  `--hs-warning`, `--hs-danger`, `--hs-font-mono`.
- **Label chip colors** come from one server helper (`EventsLive.label_color/1`
  / `label_chip_style/1`): person `--hs-blue-300` on `--hs-accent-soft`, car
  success, cat `--hs-purple-500`, dog `--hs-pink-500`, package warning, unknown
  → the person pair. Track rows use the same chips as event rows; do not invent
  a parallel palette for labels.
- Icons: **Material Symbols Outlined only**, same weights/sizes as round one
  (15–20px inline, 46px empty states). Name any new glyphs you use.
- `font-variant-numeric: tabular-nums` on every timestamp, duration, score,
  and count, as before.

## Page 5 — Tracks (`/tracks`)
The track index answers a question the events list cannot: *what did the system
see and not record?* Rows exist for objects that never triggered a clip
(`event_id` nil), and rows outlive their clips — tracks are pruned on their own
365-day clock (`retention.tracks_days`) while clips age out far sooner.

- Max width 1080px, same shell as Events. H1 "Tracks" + live count
  ("N tracks", append " match" when filters active).
- **Filter bar**: one card row, same 12px/14px padding and label-above-input
  34px fields as Events. Camera (170px select) · Label (150px select) · Zone
  (150px select) · From / To (160px date inputs) · right-aligned ghost
  "Clear filters" (`filter_alt_off`) only when filters are active.
- **Rows — text only, no thumbnail.** Each row is a card in a 10px-gap stack,
  hover raised, ending in `chevron_right` when linked. Fields available per row
  (schema `Cairn.Tracks.Track`):
  - `label` — label chip, score appended at 11px / 75% opacity like the Events
    row (`best_score`, **2 decimals**, `:erlang.float_to_binary(_, decimals: 2)`;
    nullable → `—`).
  - `camera_id` — **mono 13px/500**, `--hs-fg-1`, exactly as on event rows.
  - `started_at` / `ended_at` — `<time datetime={iso}>` with server-formatted
    local text (`"Jul 22, 18:03:11"`, the `fmt_time/1` format), `schedule`
    icon on the start like the Events row.
  - duration — `fmt_duration/1` (`"52s"`, `"1m 3s"`), `timelapse` icon; `—`
    when `ended_at` is nil (track still live).
  - `zones` — a `{:array, :string}`, frequently empty. Show as small mono chips
    on sunken bg, or `—`. Decide how many fit before truncating with "+N".
  - `end_reason` — one of `unseen` · `plugin_ended` · `stream_reset` ·
    `evicted` · `detection_disabled` · `host_restart`; nil while the track is
    live. These are terse and internal-sounding; propose how much room they get
    and whether they read as a badge, a muted suffix, or a tooltip.
  - Optional if it earns its place: `source` (`host` | `plugin`),
    `stationary_ms`, `object_id` (a 26-char ULID — mono, and it is the same id
    that appears in an event's labels).
- **Row link**: navigates to `~p"/events/#{event_id}?track=#{object_id}"`
  for the clip containing the track's **first** recorded moment
  (chronological: an arriving car's row opens its arrival clip), opening
  Event detail with that object pre-selected and its boxes drawn. A track
  may overlap several clips; the transitions list on the event page is the
  cross-clip navigation — the row itself links only to the first. Linkage
  is resolved by time overlap with surviving clips, not a stored id.
- **Unlinked rows.** A row renders unlinked when **no surviving clip
  overlaps the track's life** — it never triggered a recording, or every
  clip that did overlap has since been pruned. Non-navigable: no chevron,
  no pointer, no hover lift, plus a quiet affordance saying why ("no
  clip"). This is the single most common state on a busy camera: most
  tracks never become events. Make it read as normal, not as an error.
- **Pagination** footer identical to Events: "Showing 1–25 of N" left, sm
  secondary Previous/Next right, disabled at 40% opacity.
- **Empty state**: Events pattern — 46px faint icon, "No tracks match", 13px
  tertiary subline, sm secondary "Clear filters".

## Event detail — tracked-objects panel
The detail page is a two-column grid today: `minmax(0, 1fr) 300px`, 16px gap,
player + detections card on the left, metadata card (`#event-meta`) on the
right. The new panel is a second card in that right column, under the metadata
card — **unless you can argue for better**; the transitions list may want more
than 300px, and a full-width card below the detections timeline is a legitimate
alternative. Show us your call.

- Header "Tracked objects" 14px/600 + count, and a hint mirroring the
  detections card's "click a marker to seek".
- **Object row** — one per track whose **lifetime overlaps this clip's
  window**, ordered by `started_at`; not just tracks that ended during it.
  The parked car that arrived in this clip and left during a later one
  lists here (and on the later clip's page too). Per row:
  label chip + `best_score` (2 decimals) + the object's assigned color, a
  visibility control (`toggle-track`), and a disclosure for its transitions.
  Selected vs. unselected must be legible at a glance — the row's color is
  what the viewer will look for on the video.
- **Transitions list** (expanded): one timestamped row per moment, oldest
  first. Kinds from `Cairn.Tracks.TrackEvent`: `appeared`,
  `became_stationary`, `started_moving` — plus a synthesized final **`ended`**
  row carrying the track's `end_reason`. Three row states (see the
  functional contract):
  - **In this clip** — seek button, clock offset (`0:12`, `fmt_clock/1`).
  - **In another clip** — navigation link to that clip; show absolute
    time/date rather than an offset, plus a visible "leaves this clip"
    affordance (open question 4). The parked car's arrival clip links to
    its departure clip through these rows, and vice versa.
  - **Not recorded** — no clip covers the moment; muted, inert, quiet
    "no clip" hint.
  An icon per kind would help; propose the four glyphs.
- Panel and rows must survive a track with `label` nil, `best_score` nil, and
  zero moments (a track can have none — it appeared and was evicted).

## Event detail — bbox overlay
- Boxes are normalized `[x, y, w, h]` against the frame, interpolated between
  keyframes, redrawn per presented video frame while playing and once on seek
  while paused. Expect ~1–8 boxes on screen, occasionally more.
- Specify: stroke width, corner radius, whether there is a fill/shadow, and
  the label affix (chip above the box? id? score? nothing?). Legibility over a
  bright daylight frame *and* a near-black IR frame is the constraint; a
  hairline outline in the object color plus a dark halo is one answer.
- Specify the behavior at the frame edge (a box clipped by the frame) and what
  a *predicted* box looks like if it should differ — predicted boxes are
  included in the data and keep a path continuous through detection misses,
  but v1 carries no flag distinguishing them, so the honest answer may be
  "they look identical; nothing to design".
- The overlay never intercepts pointer events, and never covers the native
  controls strip at the bottom of the video.

## States
- **Event with no tracks** — the panel renders an empty state. Common for
  pre-feature events and for clips triggered by a track that has since been
  pruned. Copy should not imply breakage.
- **Event still recording (`status: :active`)** — no sidecar exists yet (it is
  written at finalize) and index rows appear only as tracks *end*, so the panel
  may be empty or show a subset while the clip grows. The page already shows a
  pulsing warning "Recording" badge; say what the panel and the overlay
  affordance do underneath it.
- **Track data unavailable** — no sidecar file for this event (partial event,
  pre-feature clip, or a failed clip). The panel still lists objects and
  transitions (those come from the DB), but there is nothing to draw. Decide:
  **hide the overlay affordance entirely, or disable it with an explanation?**
  Give us the copy either way.
- **Pruned / never-recorded track row** on `/tracks` — unlinked, per above.
- **Track spanning multiple clips** — the panel row appears on every
  overlapping clip's page; each page's overlay draws only that clip's box
  data; transitions cross-link the clips (rows in another clip navigate,
  rows in no clip go quiet). The commonest case: car arrives (clip 1),
  parks for hours unrecorded, leaves (clip 2).
- **Live track row** on `/tracks` — `ended_at` and `end_reason` nil, duration
  `—`. Worth a subtle "live" treatment, or worth nothing; your call.
- **Truncated sidecar** — a very long event can hit the capture cap, so boxes
  simply stop partway through the clip. No UI is planned for this; tell us if
  you think silence is wrong.

## State management (per LiveView)
- **TracksLive**: filter params (camera, label, zone, from, to) + page, all in
  the URL so back-nav from an event restores the list; a page of rows and a
  total; a set of `event_id`s resolved once per page to decide which rows link.
- **EventLive** (additions): `@tracks` = tracks overlapping the clip's
  window, moments per track each resolved to its containing clip (this one /
  another / none), the `?track=` param as an initially-selected object,
  `?t=` as an initial seek, the selected-object set (server-side, driven by
  `toggle-track`), and a single boolean for sidecar availability computed
  once at mount. Expansion of a transitions list can be client-only if you
  prefer `<details>`; say which you assumed.

## Open questions — please answer these explicitly
1. **Nav placement for `/tracks`.** A fourth topbar item next to Dashboard /
   Events / Config (the bar has room, but four is a different rhythm than
   three), or grouped under Events (a segmented control or sub-tab on the
   Events page, with the topbar unchanged)? Tracks are a power-user /
   audit-shaped view, used far less than Events. If a fourth item: which
   Material Symbols glyph?
2. **Per-object overlay colors.** Reuse the label-chip palette (all people are
   blue — instantly meaningful, but two people in frame are indistinguishable),
   or a per-object cycle (every object distinct, but color no longer means
   label)? A hybrid — label hue, varied by object — is also on the table.
   Whichever you choose, the panel row and the canvas box must agree.
3. **Transitions list: collapse long stationary runs?** A parked car produces
   `became_stationary` … `started_moving` pairs that can be hours apart, and a
   flickering object can produce dozens of pairs. Do we collapse a run into a
   single "stationary for 2h 14m" row (expandable), or list every moment
   verbatim?
4. **Cross-clip transition affordance.** How loud should "this row leaves
   the current clip" be — an inline glyph + clip date on the row, or the
   transitions list grouped under per-clip subheadings with the current
   clip's group open? It must not be mistakable for an in-clip seek, and
   the arrival↔departure hop is the case to optimize for.

## Files (expected back)
- Prototype HTML for `/tracks` and the updated `/events/:id`.
- Any `hs/shared.css` additions, clearly separated from the round-one sheet.
- A note listing every new Material Symbols glyph name used.
