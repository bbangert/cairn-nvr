# Handoff request: Cairn NVR — Camera config (Cameras, Add camera with ONVIF, Edit camera, Zone editor, Config leftovers)

## Overview

This is a **request spec** for a third design round on Cairn, the event-clip
NVR you prototyped in rounds one and two (Dashboard / Events / Event detail /
Config, then Tracks + the tracked-objects panel). Today an operator adds a
camera by editing `config.yml` on disk and pressing Reload on a read-only
Config page; zones do not exist. This round makes cameras editable from the
UI and adds polygon zones drawn over the live picture:

1. **Cameras (`/cameras`)** — the list: one row per camera with its live
   status, probe chips, plugin group, zone count, an enable toggle, Edit and
   Zones links, and an **Add camera** action.
2. **Add camera (`/cameras/new`)** — two tabs. **Find on network** scans the
   LAN for ONVIF cameras, asks for credentials, lets the operator pick the
   main and sub stream profiles, and prefills the camera form. **Enter
   stream URLs** is the same form, empty.
3. **Edit camera (`/cameras/:id/edit`)** — the same form on a saved camera:
   the id read-only, credentials write-only, the saved URL shown masked, and
   **Remove camera** behind a confirm that says what happens to history.
4. **Zone editor (`/cameras/:id/zones`)** — the live picture at its own
   aspect, polygons drawn over it, a zone list beside it. Zones filter
   presence: with zones, only detections inside a zone count and presence
   is reported per zone; with none, the whole frame counts.
5. **Config (`/config`)** — what remains: node settings (still read from
   `config.yml`, read-only), config health, and Reload. Its camera cards
   move to `/cameras`.

Everything from rounds one and two stands: same dark-only theme, same
topbar, same tokens, same primitives. Do not restate or re-derive the token
sheet. Describe only what is new and say which existing primitive each new
element is built from.

Not in this round: editing node settings (retention, windows, plugin
groups, HA token) — leave room, do not design the editor. No PTZ, no ONVIF
events, no per-zone label filters, no vertex dragging on *saved* polygons
(the draft's vertices do drag), no display names for cameras (the id is the
name).

Every attribute below is tagged **FIXED** (copied verbatim into production
markup; changing it breaks a test or a hook) or **FREE** (a proposal you may
reshape). Untagged prose is design intent.

## What we need back

Same bundle shape as rounds one and two: prototype HTML for each page and
state, additions to `hs/shared.css` only if a genuinely new primitive is
required (first compose from the existing ones), and a README listing every
new Material Symbols glyph. The eight questions earlier rounds left open are
answered in "Decisions on the open questions" below; you no longer need to
answer them, but say so if one of them fights the design. Reuse
`image-slot.js` placeholders for every `<video>`; it stays prototype-only.

Production is Phoenix 1.8 LiveView; the prototype is a visual reference,
not code to port. **The functional contract is the exception** — those ids,
`data-*` attributes, `name=` attributes, `phx-*` bindings and hook names are
load-bearing and get copied verbatim into production markup.

## Fidelity

**High-fidelity**, matching rounds one and two. New surfaces must be
indistinguishable in weight, spacing and colour from the pages already
built. Forms are new to Cairn's UI: the first real `<form>` with a submit,
the first modal (`.hs-modal` exists in `shared.css` and is unused so far),
the first async in-progress states longer than a click. Set the pattern.

## Tech baseline (deltas from round one)

- Phoenix 1.8, LiveView 1.2, Tailwind v4 + daisyUI (unused by the shipped
  pages — everything is `hs-*` primitives with inline styles, as ported).
- Layout wrapper: `<Layouts.app flash={@flash} page={atom}>`; the nav gains
  a `:cameras` atom (decision 1 below).
- Every `<video>` is driven by a JS hook that owns its media source (`src`
  for MSE, `srcObject` for WebRTC); the hook contract carries the transport
  in the element id (corrected below — round one's doc was stale on this
  and has been fixed alongside this request).
- Long operations (network scan, ONVIF sign-in, ffprobe, applying a save)
  run asynchronously on the server and stream state back; the page stays
  interactive and shows an in-progress state. Design each.
- Icons: Material Symbols Outlined only. Numbers: tabular.
- CSP is `script-src 'self'`: no inline scripts survive the port. Anything
  interactive is either a LiveView binding or a bundled hook.

## Functional contract (must be kept verbatim)

### Carried over from rounds one and two, corrected

- **Live player** (dashboard tile, and reused on the zone editor with one
  style change) — FIXED:
  ```heex
  <video
    id={"camera-video-#{cam.id}-#{transport}"}
    phx-hook={if transport == :webrtc, do: "WebrtcPlayer", else: "MsePlayer"}
    phx-update="ignore"
    data-camera-id={cam.id}
    data-hls-url={~p"/hls/#{cam.id}/index.m3u8"}
    muted autoplay playsinline
  ></video>
  ```
  The id carries the transport (`-webrtc` / `-mse`) and the hook is chosen
  server-side per camera (default `:webrtc`; flipped by the toggle or by a
  `transport_failed` report). The suffix is load-bearing, not cosmetic:
  under `phx-update="ignore"` the id change is what makes LiveView replace
  the element and swap the hook. Never set `src` or `srcObject`; never
  remove `phx-update="ignore"`. Inbound, the hooks read exactly two
  attributes and not symmetrically — `MsePlayer` reads `data-camera-id` and
  `data-hls-url`, `WebrtcPlayer` only `data-camera-id`. Outbound, both push
  `webrtc_active {camera_id, width, height}` and `webrtc_inactive`, and
  `WebrtcPlayer` also `transport_failed`; every LiveView that hosts the
  element (the zone editor included) handles those three plus
  `toggle-transport`.
- **Transport toggle** — FIXED: `#camera-transport-{id}[data-transport]`
  with two buttons `phx-click="toggle-transport" phx-value-camera={id}
  phx-value-transport="mse|webrtc"`.
- **Status badge** — FIXED: `#camera-status-{id}[data-status]`, six values
  `connecting running backoff stalled transcode_unavailable unknown`, with
  the round-one colours, pulses and full-area messages.
- **Detection overlay** — FIXED: `#camera-overlay-{id}` (`pointer-events:
  none`, percent-positioned boxes rendered by the server), and
  `#camera-detections-{id}` summary.
- **Config page** — FIXED: `#config-reload[phx-click="reload"]`,
  `#reload-result[data-ok="true|false"]`, `#config-health`,
  `#config-globals`; the badge vocabulary `added {id}` (success) ·
  `removed {id}` (danger) · `restarted {id}` (accent) · `updated {id}`
  (neutral) — "restarted" and "updated" are different because the operator
  sees the difference: an updated camera keeps its stream and live tracks.
- **Timestamps** — `<time datetime={iso}>` with server-formatted local text.
- **Copy affordance** — FIXED: `phx-hook="CopyText" data-copy={text}`.

### Routes and nav

FIXED:

| route | LiveView | `page=` |
|---|---|---|
| `/cameras` | `CamerasLive` `:index` | `:cameras` |
| `/cameras/new?tab=scan\|manual` | `CamerasLive` `:new` | `:cameras` |
| `/cameras/:id/edit` | `CamerasLive` `:edit` | `:cameras` |
| `/cameras/:id/zones` | `ZonesLive` | `:cameras` |
| `/config` | `ConfigLive` (stays) | `:config` |

`?tab=` defaults to `scan`. Tab switches are `patch` links, so the tab is
in the URL and back-nav restores it. Nav links are `.cairn-nav` /
`.cairn-nav--active` as before. The nav is five items — Dashboard · Events
· Tracks · **Cameras** · Config — with Cameras on the `video_settings`
glyph (decision 1).

### Page: Cameras `/cameras`

```heex
<main id="cameras">
  <.link id="cameras-add" navigate={~p"/cameras/new"} class="hs-btn hs-btn--primary">Add camera</.link>

  <section :if={@save_result} id="save-result" data-ok={@save_result.ok}> … </section>   <%!-- FIXED id; badge vocabulary above --%>

  <div :if={@cameras == []} id="cameras-empty"> … </div>

  <ul id="cameras-list">                                                   <%!-- plain list, not a stream: 1–9 rows --%>
    <li :for={cam <- @cameras}
        id={"camera-row-#{cam.id}"}
        data-status={status(cam.id)}                                       <%!-- the six values --%>
        data-loaded={loaded(cam.id)}                                       <%!-- loaded | skipped | disabled | unloaded --%>
        data-zones={length(cam.zones)}>
      <span>{cam.id}</span>                                                <%!-- mono, the camera's name --%>
      <span :for={{chip, n} <- Enum.with_index(probe_chips(cam.id))} id={"probe-#{cam.id}-#{n}"} data-chip={chip}>{chip}</span>
      <button id={"camera-enabled-#{cam.id}"} class="hs-tog" role="switch" aria-checked={cam.enabled}
              phx-click="toggle-enabled" phx-value-id={cam.id}></button>
      <.link navigate={~p"/cameras/#{cam.id}/edit"}>Edit</.link>
      <.link navigate={~p"/cameras/#{cam.id}/zones"}>Zones</.link>
      <button phx-click="delete" phx-value-id={cam.id} data-confirm="…">Remove</button>
    </li>
  </ul>
</main>
```

FIXED: every id and `data-*` above, the two link targets, the two events.
`data-loaded` is what the config loader made of the row: `loaded` (running
config has it), `skipped` (the row is enabled but the loader refused it —
its errors render inline on the row, and it stays editable), `disabled`
(the toggle is off; the camera is not running and keeps its history and
retention), `unloaded` (the running config has no such camera and nothing
refused this row by name — the load failed as a whole, and the reason is in
the `#cameras-load-errors` banner above the list, not on the row). FREE: row layout, what else the row shows (plugin group name,
retention, transcode / not-H.264 / transcode-unavailable chips as on
today's config cards), whether rows are cards or a table (`.hs-table`
exists).

The toggle is a fleet edit: flipping it may restart *other* cameras (see
"The restart set"), so its label or help says so before the tap, and a
refusal (the loader rejects the fleet without this camera, or with it) is
shown on the row as the loader's own strings.

### Page: Add camera `/cameras/new`

**Tabs** — FIXED:
```heex
<nav id="camera-new-tabs" role="tablist">
  <.link id="tab-scan"   patch={~p"/cameras/new?tab=scan"}   role="tab" aria-selected={@tab == :scan}>Find on network</.link>
  <.link id="tab-manual" patch={~p"/cameras/new?tab=manual"} role="tab" aria-selected={@tab == :manual}>Enter stream URLs</.link>
</nav>
```

**Scan panel** (scan tab) — FIXED ids, attributes, events, `name=`s:
```heex
<section id="onvif-scan" data-state={@scan.state}>            <%!-- idle | scanning | done | error --%>
  <form id="onvif-scan-form" phx-submit="scan">
    <select name="interface"> … </select>                       <%!-- "" = default route; else one option per LAN interface --%>
    <button id="onvif-scan-start" type="submit" phx-disable-with="Scanning…">Scan network</button>
  </form>

  <ul id="onvif-devices">
    <li :for={d <- @scan.devices}
        id={"onvif-device-#{ip_slug(d.ip)}"}                     <%!-- 192.168.1.20 → onvif-device-192-168-1-20 --%>
        data-ip={d.ip}
        data-added={d.added_as}>                                 <%!-- the saved camera id whose URL host matches, else absent --%>
      {d.name} · {d.model} · {d.ip}
      <button phx-click="pick-device" phx-value-ip={d.ip}>Add</button>
    </li>
  </ul>

  <form id="onvif-by-ip" phx-submit="pick-device">              <%!-- the no-multicast escape hatch --%>
    <input name="ip" inputmode="decimal" placeholder="192.168.1.20">
    <button type="submit">Add by IP</button>
  </form>
</section>
```
A device whose host already backs a saved camera shows "added as {id}"
(neutral badge) with **Add still enabled** — the same host can carry a
second channel on another port or path (decision 8).

**Credentials modal** — FIXED:
```heex
<dialog id="onvif-credentials" class="hs-modal" data-state={@connect.state} data-error={@connect.error}>
  <%!-- state: idle | connecting | error   error: unauthorized | unreachable | timeout | no_profiles | nil --%>
  <form id="onvif-credentials-form" phx-submit="connect">
    <input name="username" autocomplete="off">
    <input name="password" type="password" autocomplete="new-password">
    <button type="submit" phx-disable-with="Connecting…">Connect</button>
    <button type="button" phx-click="cancel-connect">Cancel</button>
  </form>
</dialog>
```
The password input never carries a `value=`. FREE: the modal's copy, a
"which user?" hint (many cameras need a dedicated ONVIF user), how the error
strip sits in the modal.

**Profiles step** — FIXED:
```heex
<section id="onvif-profiles" data-state={@profiles.state}>     <%!-- fetching | ready --%>
  <form id="onvif-profiles-form" phx-change="pick-profiles">
    <article :for={p <- @profiles.list}
             id={"onvif-profile-#{p.token}"}                    <%!-- token slugged if needed --%>
             data-role={role(p)}                                 <%!-- main | sub | none --%>
             data-codec={p.codec}>
      … name, {w}×{h}, {codec}, {fps} fps, {bitrate} kbps chips; the stream URI (mono, credential-less)
      <input type="radio" name="main_profile" value={p.token}>
      <input type="radio" name="sub_profile"  value={p.token}>
    </article>
    <input type="radio" name="sub_profile" value="">             <%!-- "No sub stream" --%>
  </form>
  <button id="onvif-use" phx-click="use-profiles">Use these streams</button>
</section>
```
`use-profiles` fills the camera form below (URLs, username, password, an id
slugged from the device name) and reveals it. FREE: cards vs rows, radio vs
two-column picker (keep the `name=`/`value=` pairs whatever the control
looks like), the prefilled-banner copy.

**Camera form** (manual tab, ONVIF prefill, and Edit share it) — FIXED
`id`, `data-mode`, events, and every `name=`:
```heex
<.form for={@form} id="camera-form" data-mode={@live_action} phx-change="validate" phx-submit="save">
  <%!-- data-mode: new | edit.  Each field sits in a .hs-field; the ones that restart the
       camera carry data-restart="true" on the wrapper (FIXED attribute, FREE styling). --%>

  <input name="camera[id]">                              <%!-- new: editable, [a-z0-9][a-z0-9_-]*; edit: read-only --%>
  <input name="camera[rtsp_url]">                        <%!-- restart --%>
  <input name="camera[substream_url]">                   <%!-- restart; optional --%>
  <input type="checkbox" name="camera[clear_substream]"> <%!-- FIXED; restart; edit only, and only when the saved row has a sub URL: "Remove sub stream" (a blank field means keep) --%>
  <input name="camera[username]" autocomplete="off">     <%!-- restart (composes into the URLs) --%>
  <input name="camera[password]" type="password" autocomplete="new-password">  <%!-- restart; write-only, never value= --%>
  <select name="camera[plugin]">                         <%!-- restart; "" = no detection; options = plugin groups from config.yml --%>
  <select name="camera[ingest]">                         <%!-- restart; ffmpeg | rtsp --%>
  <input type="checkbox" name="camera[transcode]">       <%!-- restart; rendered as .hs-tog --%>

  <input name="camera[pre_window_seconds]">              <%!-- restart (ring buffer is sized at start); blank = inherit --%>
  <input name="camera[post_window_seconds]">             <%!-- hot; blank = inherit --%>
  <input name="camera[max_event_seconds]">               <%!-- hot; blank = inherit --%>
  <input name="camera[retention_days]">                  <%!-- hot; blank = inherit --%>
  <input name="camera[annotation_offset_ms]">            <%!-- hot; signed integer, |ms| ≤ 30000 --%>

  <%!-- per-label tier rows — see the component section --%>
  <fieldset id="camera-labels">
    <div :for={{row, n} <- rows} id={"label-row-#{n}"} data-label={row.label}>
      <input name={"camera[labels][#{n}][label]"} list="known-labels">
      <input name={"camera[labels][#{n}][min_score]"} inputmode="decimal">     <%!-- restart --%>
      <input name={"camera[labels][#{n}][track]"}     inputmode="decimal">     <%!-- hot --%>
      <input name={"camera[labels][#{n}][record]"}    inputmode="decimal">     <%!-- hot --%>
      <input name={"camera[labels][#{n}][retention_days]"}>                    <%!-- hot; FREE: here or in Advanced --%>
      <button type="button" phx-click="remove-label-row" phx-value-index={n}>Remove</button>
    </div>
    <datalist id="known-labels"> … </datalist>
    <button type="button" phx-click="add-label-row">Add label</button>
  </fieldset>

  <details id="camera-advanced">                          <%!-- Advanced --%>
    <select name="camera[tracker]">                       <%!-- restart; "" = profile/global default --%>
    <input name="camera[max_live_tracks]">                <%!-- restart --%>
    <input name="camera[max_unseen_ms]">                  <%!-- hot --%>
    <input name="camera[stationary_after_ms]">            <%!-- hot --%>
    <textarea name="camera[motion_json]">                 <%!-- restart; verbatim JSON --%>
    <input name="camera[extra_ffmpeg_args]">              <%!-- restart; whitespace-separated argv --%>
  </details>

  <button id="camera-probe" type="button" phx-click="probe">Test stream</button>
  <section id="probe-result">
    <div id="probe-main" data-state={@probe.main.state}> … </div>   <%!-- idle | running | ok | error --%>
    <div id="probe-sub"  data-state={@probe.sub.state}>  … </div>   <%!-- only when a sub URL is set --%>
  </section>

  <div :if={@form_errors != []} id="camera-form-errors"> … </div>    <%!-- errors no field claims --%>
  <button id="camera-save" type="submit" phx-disable-with="Saving…">Save camera</button>
</.form>

<section :if={@save_result} id="save-result" data-ok={@save_result.ok} data-phase={@save_result.phase}>
  <%!-- phase: applying | done --%>
</section>
```

**The restart set**, for the chip: `rtsp_url substream_url username password
plugin ingest transcode extra_ffmpeg_args motion_json pre_window_seconds
tracker max_live_tracks` and every `min_score` cell. Everything else is hot
("updated", the camera keeps its stream). Two precisions the chip must not
overstate: `pre_window_seconds`, `tracker` and `max_live_tracks` restart
only when the *resolved* value (camera override → profile → global)
changes, so typing the value the camera already inherits is an update, not
a restart; and a save can restart cameras whose own fields did not move at
all (adding, removing, disabling or re-pointing a camera changes the fleet
size and can move the detection ladder rung for every camera on the same
plugin group). The chip is therefore a prediction; the `restarted` /
`updated` badge on the result card comes from the actual diff, never from
the dirty set. A restart also fires `presence_cleared` to Home Assistant for
that camera — say so near the Save button when a restart field is dirty
(decision 4).

### Page: Edit camera `/cameras/:id/edit`

Same `#camera-form` with `data-mode="edit"`, plus — FIXED:
```heex
<div id="camera-url-readout">{mask_url(cam.rtsp_url)}</div>            <%!-- rtsp://user:•••••@host/… ; also the sub URL when set --%>
<div id="camera-zones-summary" data-zones={length(cam.zones)}>
  … "2 zones" / "No zones — presence counts the whole frame"
  <.link navigate={~p"/cameras/#{cam.id}/zones"}>Edit zones</.link>
</div>
<button id="camera-remove" type="button" phx-click={show_modal("camera-remove-confirm")}>Remove camera</button>
<dialog id="camera-remove-confirm" class="hs-modal">
  <form phx-submit="remove">
    <input type="hidden" name="id" value={cam.id}>
    <button type="submit" class="hs-btn hs-btn--danger" phx-disable-with="Removing…">Remove {cam.id}</button>
    <button type="button" phx-click={hide_modal("camera-remove-confirm")}>Cancel</button>
  </form>
</dialog>
```
Credential rule (FIXED, applies to every page): a saved credential is never
rendered — not in `value=`, not in a tooltip, not in the readout. `mask_url`
output is the only form a saved URL takes on screen:
`rtsp://user:•••••@host/…` for userinfo, `?password=•••••` for a credential
carried as a query parameter. On edit the `camera[password]` field is empty with help
"leave blank to keep"; `camera[username]` is prefilled; `camera[rtsp_url]`
is prefilled only when the saved URL carries no credential (userinfo or
query), otherwise it is empty with "leave blank to keep the saved URL".
`show_modal` / `hide_modal` are the stock show/hide JS helpers; their names
are FREE. `data-confirm` is the destructive pattern on the list row; the
modal is preferred on Edit because the history note needs room.

### Page: Zone editor `/cameras/:id/zones`

FIXED — every id, `data-*`, event and `name=` below, and the `<video>`'s
inline style:

```heex
<main id="zone-editor" data-camera-id={@camera.id} data-dirty={@dirty?}>
  <h1>{@camera.id} · Zones</h1>
  <.link navigate={~p"/cameras/#{@camera.id}/edit"}>Back to camera</.link>

  <%!-- padding 0, no explicit height, not stretched by a flex/grid parent:
        the coordinate identity below depends on it --%>
  <div id="zone-frame" style={"aspect-ratio: #{w} / #{h};"}>
    <%!-- the dashboard tile's video, verbatim, with cover → contain:
          id carries the transport, hook chosen server-side --%>
    <video
      id={"camera-video-#{@camera.id}-#{@transport}"}
      phx-hook={if @transport == :webrtc, do: "WebrtcPlayer", else: "MsePlayer"}
      phx-update="ignore"
      data-camera-id={@camera.id}
      data-hls-url={~p"/hls/#{@camera.id}/index.m3u8"}
      muted autoplay playsinline
      style="position: absolute; inset: 0; width: 100%; height: 100%; object-fit: contain;"
    ></video>

    <%!-- live detections, only over WebRTC with a frame on screen; pointer-events: none --%>
    <div :if={@ready? and @transport == :webrtc} id="zone-overlay">
      <div :for={det <- @detections} class="zone-det" data-in-zones={hits(det)}>
        <Bbox.bbox ... />
      </div>
      <span :for={det <- @detections} class="zone-foot" data-in-zones={hits(det)}></span>
    </div>

    <%!-- the editing surface; interactive only while data-ready="true" --%>
    <div id="zone-surface" phx-hook="ZoneEditor"
         data-camera-id={@camera.id} data-ready={@ready?} data-mode={mode(@draft)}>
      <svg id="zone-svg" viewBox="0 0 1 1" preserveAspectRatio="none">
        <polygon :for={z <- @zones} id={"zone-polygon-#{z.id}"} data-zone-id={z.id}
                 data-selected={z.id == @selected} points={points(z.points)}
                 vector-effect="non-scaling-stroke" />
        <polyline :if={@draft} id="zone-draft-path" data-closed={@draft.closed?} points={points(@draft.points)}
                  vector-effect="non-scaling-stroke" />
      </svg>
      <div :for={{[x, y], i} <- Enum.with_index(draft_points(@draft))}
           id={"zone-vertex-#{i}"} data-vertex={i} data-x={x} data-y={y}
           style={"left: #{x * 100}%; top: #{y * 100}%;"}></div>
      <svg id="zone-ghost" phx-update="ignore" viewBox="0 0 1 1" preserveAspectRatio="none">
        <line vector-effect="non-scaling-stroke" style="display: none;" />
        <polygon vector-effect="non-scaling-stroke" style="display: none;" />
      </svg>
    </div>

    <div :if={!@ready?} id="zone-waiting">Waiting for the first frame…</div>
    <div :if={@ready? and @transport == :mse} id="zone-live-hint">Switch to Low latency to see live detections.</div>
    <div :if={@notice} id="zone-notice">{@notice}</div>
  </div>

  <div id={"camera-transport-#{@camera.id}"} data-transport={@transport}>
    <button phx-click="toggle-transport" phx-value-camera={@camera.id} phx-value-transport="mse">Standard</button>
    <button phx-click="toggle-transport" phx-value-camera={@camera.id} phx-value-transport="webrtc">Low latency</button>
  </div>

  <div id="zone-toolbar">
    <button phx-click="zone-close" disabled={!closable?(@draft)}>Close</button>
    <button phx-click="zone-undo" disabled={is_nil(@draft)}>Undo point</button>
    <button phx-click="zone-cancel" disabled={is_nil(@draft)}>Cancel</button>
    <span :if={@error} id="zone-error" class="hs-err">{@error}</span>
  </div>

  <form :if={@draft && @draft.closed?} id="zone-form" phx-change="zone-validate" phx-submit="zone-save">
    <input name="zone[name]" class="hs-input" phx-debounce="300" />
    <input name="zone[id]" class="hs-input" disabled={@draft.editing != nil} />
    <button type="submit">Save zone</button>
  </form>

  <ul id="zone-list">
    <li :for={z <- @zones} id={"zone-row-#{z.id}"} phx-click="zone-select" phx-value-id={z.id}>
      <span class="hs-mono">{z.id}</span> {z.name} · {length(z.points)} points
      <button phx-click="zone-edit" phx-value-id={z.id}>Edit outline</button>
      <form phx-submit="zone-rename"><input type="hidden" name="id" value={z.id} /><input name="name" /></form>
      <button phx-click="zone-delete" phx-value-id={z.id} data-confirm="Delete this zone? Presence for it clears.">Delete</button>
    </li>
  </ul>
  <div :if={@zones == [] and is_nil(@draft)} id="zone-empty">No zones — the whole frame counts.</div>
  <div :if={@inert?} id="zone-inert">Zones are stored but this camera runs no presence detection.</div>
  <div :if={@camera.substream_url} id="zone-aspect-note">Zones are drawn on the main stream; the sub stream must share its aspect ratio.</div>
  <div :if={@result} id="zone-result" data-ok={@result.ok}>…updated / error list…</div>
</main>
```

**Ids** (stable): `zone-editor`, `zone-frame`, `camera-video-{id}-{transport}`,
`zone-overlay`, `zone-surface`, `zone-svg`, `zone-polygon-{zone_id}`,
`zone-draft-path`, `zone-vertex-{i}`, `zone-ghost`, `zone-waiting`,
`zone-live-hint`, `zone-notice`, `camera-transport-{id}`, `zone-toolbar`,
`zone-error`, `zone-form`, `zone-list`, `zone-row-{zone_id}`, `zone-empty`,
`zone-inert`, `zone-aspect-note`, `zone-result`.

**`data-*`**: `data-camera-id`, `data-ready` (`true|false`), `data-mode`
(`idle|drawing|closed`), `data-zone-id`, `data-selected`, `data-closed`,
`data-vertex`, `data-x`/`data-y`, `data-in-zones` (space-separated ids,
empty = counts nowhere), `data-transport`, `data-ok`, `data-dirty`.

**Events the hook pushes**: `zone-point {x, y}` (tap on the surface),
`zone-close` (tap on the first vertex with three or more placed, or Enter),
`zone-vertex-move {index, x, y}` (drag a draft vertex; the drag itself is a
client-only ghost), `zone-undo` (Backspace), `zone-cancel` (Escape). The
toolbar buttons push the same names. Coordinates are normalized 0..1,
origin top-left, y down; the surface reads its own rectangle at the moment
of each event, so resizing the window never moves a polygon.

**How the geometry works, so the layout keeps it true.** `#zone-frame` is
a box whose `aspect-ratio` is the *frame's* (from the player's reported
dimensions; the probe's while none; `16 / 9` before either), the video is
`object-fit: contain` inside it, and the surface is `position: absolute;
inset: 0`. The displayed frame therefore fills the box edge to edge, and a
tap's fraction of the surface *is* the normalized frame coordinate — no
letterbox math anywhere. That identity has four layout preconditions,
listed under "What design must NOT change". A 4:3 camera shows 4:3, never
cropped; the box's width rule (`min(100%, calc((100vh - 240px) * W / H))`)
keeps a tall frame on one screen — the 240 px chrome allowance is FREE.

Zone identity (FIXED, decided): `id` is an immutable slug
(`[a-z0-9][a-z0-9_-]*`, ≤ 32 chars, unique per camera, set at creation, the
key Home Assistant sees); `name` is free text (≤ 64 chars) and renamable. A
zone has 3–64 vertices. A detection counts in every zone containing it;
nested and overlapping polygons are allowed and never rejected. A polygon
that crosses *itself* is refused at Close (decision 6).

### Page: Config `/config` (what remains)

FIXED: `#config-reload`, `#reload-result[data-ok]`, `#config-health`,
`#config-globals` unchanged. `#config-cameras` and `#config-camera-{id}` go
away; in their place a link row — FIXED id `#config-cameras-link` → `/cameras`.
Header copy changes from "Read-only view of {path} — edit the file, then
reload" to something like "Node settings, read from {path}. Cameras are
managed on Cameras." Reload stays: it re-reads the file's globals and the
database's cameras together, so its result card may still show camera
badges.

Config health gains an import section — FIXED `#config-import`: an info
line "Cameras imported from {path} on {date}" (from the import marker), and
whichever of the loader's two warnings applies, verbatim:

- `config.yml still lists cameras: — the database is the source of truth;
  remove the key`
- `config.yml: cameras changed since they were imported — use Import again
  on /config to replace them, or remove the key`

Under the second, a button — FIXED `#config-reimport` `phx-click="reimport"`
with a `data-confirm` — replaces every saved camera with the file's list
(zones included). The confirm copy says that: "Replace all N saved cameras
with the M in config.yml? Zones drawn in the UI are lost." Result renders in
`#reload-result` with the usual badges.

### Dashboard deltas

FIXED: `#empty-state` keeps its id; its copy drops "Add one to `config.yml`
and reload" for an **Add camera** link `id="empty-state-add"` →
`/cameras/new`. The tile's `<h2>` becomes a link to `/cameras/:id/edit`
(decision 2); there is no per-tile Zones affordance. Design-invisible but
worth knowing: after a save elsewhere the dashboard re-mounts itself to
pick up the new camera list, so a tile grid may re-render while someone is
watching it.

## Design tokens & reuse

No new tokens unless something below genuinely has no home. Build from
`.hs-card`, `.hs-field` / `.hs-input` / `.hs-input--error` / `.hs-help` /
`.hs-err`, `.hs-btn` and its `--primary --secondary --ghost --danger --sm
--icon` variants, `.hs-tog` (aria-checked), `.hs-badge` and `--success
--warning --danger --accent --neutral`, `.hs-dot`, `.hs-modal-backdrop` /
`.hs-modal` and its `__head __title __sub __body __foot`, `.hs-table`,
`.label-chip` styling from `EventsLive.label_chip_style/1` (person blue,
car success, cat purple, dog pink, package warning, unknown → person), the
probe-chip style from the config cards (mono 12px on sunken), `.tnum`,
`.ms`, `cairn-pulse` / `cairn-spin`. Tokens: `--hs-fg-1…4`,
`--hs-bg-surface / -sunken / -raised / -canvas`, `--hs-border-1 / -2 /
-strong`, `--hs-accent / -soft`, `--hs-success / -soft`, `--hs-warning /
-soft`, `--hs-danger / -soft`, `--hs-font-mono`, `--hs-shadow-focus`.
Tabular numerics on every threshold, resolution, fps, bitrate, count and
timestamp. Name every new glyph.

## Page specs

### Cameras

- Same 980–1080px shell as Config. H1 "Cameras" + count ("4 cameras · 3
  running"). **Add camera** primary top-right.
- Row: camera id (mono 13px/500), status badge (six values, same treatment
  as the tile's pill but on a surface — not over video), probe chips
  (codec / WxH / fps / profile, or a single warning "not probed yet"),
  plugin group name, "no detection", or "invalid" when the refused row's
  settings hold something that is not a group name, zone count ("2 zones" or "whole
  frame"), the transcode / not-H.264 / transcode-unavailable chips from
  today's config cards, the enable toggle (`.hs-tog`), then Edit (secondary
  sm), Zones (ghost sm) and Remove (ghost danger sm, `data-confirm`).
- Backoff / stalled / transcode-unavailable rows should read as needing
  attention without shouting — the dashboard already shouts.
- A `skipped` row (the loader refused it) reads as a problem to fix, not a
  camera that is down: warning border, the loader's strings inline, Edit as
  the call to action; no status badge (it has none). A `disabled` row is
  quiet and dimmed, toggle off, still has Edit / Zones / Remove.
- Empty state: 46px `videocam`, "No cameras yet", "Find one on your network
  or enter its stream URLs", primary "Add camera".
- `#save-result` card at the top when the operator arrives from a create,
  a toggle or a remove (decision 7).

### Add camera — Find on network

- Two tabs under the H1, `role="tab"`; the scan tab is the default.
- Scan bar: interface select (label "Scan from", default "Default
  interface") + **Scan network**. Below it the device list. **Add by IP**
  sits under the list, quiet until the none-found state makes it the
  primary suggestion.
- Device row: name (from the camera's ONVIF scope; may be absent → show
  model or the IP as the title), model, IP mono, an "added as {id}" neutral
  badge when `data-added` is set (Add stays enabled), otherwise plain;
  **Add** (secondary sm). Scans return all rows at once after ~3 s; there
  is no trickle-in to animate.
- Sign-in modal (`.hs-modal`, 520px): title "Sign in to {name}", sub
  "{ip} — Cairn reads the camera's stream URLs over ONVIF and saves these
  credentials into its RTSP URLs", username, password, Cancel + Connect.
- Profiles: one card per profile — name (mono), chips `2560×1440` ·
  `H.264` · `20 fps` · `4096 kbps`, the stream URI (mono 11px, credential-
  less, with `CopyText`), and the main/sub pick. Main pre-selected on the
  largest, sub on the smallest when there are two or more. A non-H.264
  profile picked as main gets the warning chip "not H.264 — enable
  transcode or pick an H.264 profile". **Use these streams** primary.
- After Use: the camera form appears prefilled with a banner "Filled from
  {name} ({ip}) — change anything below", id slugged from the name
  (`front_door`), and Test stream ready to run.

### Add camera — Enter stream URLs / the camera form

- One column, 640–720px, grouped: **Stream** (id, main URL, sub URL,
  username, password, ingest, transcode, plugin group), **Detection
  thresholds** (the per-label rows), **Windows & retention** (pre / post /
  max, retention days, annotation offset), **Advanced** (collapsed
  `<details>`), then Test stream + probe chips, then Save.
- Every restart-class field carries a small "restarts camera" chip inside
  its `.hs-field` label row (decision 4). Hot fields say nothing.
- Help text where the parser's rule is not obvious: id "lowercase letters,
  digits, `_` and `-`; it names this camera everywhere and cannot change
  later"; sub URL "must be rtsp://"; ingest "rtsp needs an rtsp:// URL and
  no transcode"; annotation offset "±30000 ms".
- Field errors are the loader's own strings with the `camera {id}:` prefix
  stripped, under the field they name; strings that name no field go in
  `#camera-form-errors` above Save.
- Test stream: secondary button; while running "Probing… up to 15 s" with
  the spinner glyph; results as chips (the config-card style) per stream.

### Per-label tier rows (component)

One row per label the operator names, plus a first, fixed **default** row.
Columns: **Label** · **Detect ≥** (`min_score`, the wire floor the engine
applies; restart-class) · **Track ≥** (`track`, which detections get a
database row; hot) · **Record ≥** (`record`, which earn video; hot) ·
optional **Keep (days)** · remove. Values 0..1 shown to two decimals,
`inputmode="decimal"`, tabular — note the loader's error strings print the
same numbers as Elixir floats (`0.4`, `1.0`), not two-decimal, so an error
under a cell showing `0.40` reads `(0.4)`.

The rule, surfaced inline: per label, effective **Record ≥ Track ≥
Detect**. "Effective" matters for blanks:

- **default row**: Detect always has a value (0.50 built-in when blank —
  show the ghost). Track / Record default are optional.
- **Label row, Detect blank**: inherits the default row's Detect — ghost
  the inherited number.
- **Track (or Record) blank**, three distinct states the row must make
  legible:
  1. *No rule anywhere in that column* → the tier is absent: everything
     above the floor qualifies. Ghost "= Detect".
  2. *Column has a default rule* → this label inherits it. Ghost the
     default's number.
  3. *Column has rules for other labels but no default* → this label is
     **excluded** from that tier (no rows / no video for it). This is the
     trap state: an explicit `excluded` pill (`.hs-badge--warning`, sm)
     sits in the cell, with a title "no track: rule and no default — this
     label gets no {rows | video}" (decision 5). It must never look like
     an inherited ghost number.
- A Record column with no rules at all resolves to Detect for every label:
  a Track value above Detect with no Record rule therefore films
  detections it never writes a row for. The loader rejects that — see the
  last error below.

Error states (the loader's strings, camera prefix stripped, shown under the
offending cell; the row gets `data-error`):

- Detect cell: `min_score values must be 0..1 (person)`.
- Track / Record cell: `track values must be a number or a map of
  {min_score: 0..1} (person)` — in the form, read as "must be 0..1".
- `track.person (0.4) must be >= min_score.person (0.5)` → Track cell.
- `record.person (0.5) must be >= min_score.person (0.6)` → Record cell.
- `record.person (0.5) must be >= track.person (0.6)` → Record cell.
- `track.person (0.6) must be <= the effective record threshold (0.5) —
  with no record: block video falls back to min_score, so a clip could
  exist with no track row. Give person a record: rule, or lower
  track.person` → row-level, spanning Track and Record.
- Routing caveat: the `{label}` in these strings is the *resolved* label
  from the union of all three columns, not the row that holds the rule.
  `min_score: {person: 0.8}, record: {default: 0.7}` yields `record.person
  (0.7) must be >= min_score.person (0.8)` — the error names the person
  row, whose Record cell is blank and ghosts the inherited 0.70, while the
  value that must change sits in the default row. The cell it lands on
  must make that legible (the ghost number is what the error quotes); FREE
  whether the default row's cell is highlighted too.
- Row-level: empty label; duplicate label; a label with every cell blank
  (nothing to save — FREE whether that is an error or the row just drops).

Warning state (column-level, on the Track header): when the chosen plugin
group resolves to a tier-1 profile and any Track cell has a value, `track:
has no effect at tier 1 — tier 1 runs no tracker and persists no track
rows; record: gates presence recordings`. Show it the moment the plugin
select changes, not only after Save — with the caveat that the loader
returns warnings only for a candidate with zero errors, so while a cell
error is showing the warning is unavailable and the header must not
flicker between the two.

Restart marking: the Detect column header carries the "restarts camera"
chip once; Track and Record do not.

### Advanced (JSON)

Collapsed `<details>` "Advanced". Two verbatim fields plus the tracking
overrides:

- **Motion gate (JSON)** `camera[motion_json]` — mono textarea, 3–6 rows,
  help "Scene config for the motion gate, passed through as written.
  Restarts the camera." Error states: `motion_json: {parser message}`,
  `motion_json must be a JSON string`, and on tier-2 plugin groups the
  loader's rejection. Warning (valid-but-inert): `motion_json resolves to
  no detector, so the gate is never built — add "enabled": true to it` —
  show it as a warning under the field, not as an error.
- **Extra ffmpeg arguments** `camera[extra_ffmpeg_args]` — mono single-line
  input, placeholder `-rtsp_transport tcp`, help "split on spaces — quotes
  are not honoured; restarts the camera". No form-level error state: the
  parser accepts any string, blank splits to nothing, and Test stream
  (ffprobe) does not read this field. A bad value surfaces only after
  Save, as the restarted camera's ffmpeg exits and its badge goes to
  `backoff` — the help text and the save-result copy are the only warning
  the operator gets.
- **Tracking overrides** — tracker (select, "profile default" + the cores),
  max live tracks, max unseen ms, stationary after ms — plain fields, blank
  = inherit; tracker and max live tracks restart.

### Edit camera

- Header: camera id (mono 14px/500) + its live status badge (six values) —
  the operator often lands here because the dashboard showed "Unreachable".
- Masked URL readout(s) in the sunken mono block from the config cards,
  then the form with `camera[rtsp_url]` per the credential rule.
- Zones summary card between Stream and thresholds: "2 zones · Edit zones"
  or "No zones — presence counts the whole frame · Draw zones".
- Remove camera: ghost danger at the bottom, opening the confirm modal.
  Modal copy (FREE wording, FIXED facts): "Recording stops now. Its events,
  clips and tracks stay under the id {id} until retention removes them.
  Home Assistant keeps the device until it next reads the camera list."
  Danger button "Remove {id}".

### Zone editor

- Layout: stage left / rail right on laptop **and** on the landscape
  tablet (decision 3) — the stage's width rule shrinks it to keep the
  whole frame plus the toolbar on one screen; no bottom sheet. The stage
  is the frame at its own aspect inside a sunken well; the status badge
  and the full-area message overlay from the tile apply on top of it.
- Vertex handles are 28 px (visible dot smaller, FREE) so a finger can
  land on the first vertex to close; a press that travels under 6 px is a
  tap, more is a drag.
- Right rail: the toolbar (Close / Undo point / Cancel + the inline
  error), the zone form once a draft is closed (name + id, the id
  disabled when editing an existing outline), then zone rows (id mono,
  name, point count, Edit outline / rename / Delete), then the empty,
  inert and sub-stream notes. Enter closes, Esc cancels, Backspace undoes
  when focus is not in an input (hook-owned; the buttons are the
  contract).
- Transport: the editor prefers Low latency (WebRTC) so live boxes show;
  on Standard (MSE) the picture plays but boxes do not — `#zone-live-hint`
  says so quietly.
- Live boxes while editing: every detection draws with a foot marker at
  its bottom centre (the point the zone test uses); boxes whose foot is
  in no zone are dimmed. That is how the operator sees the street
  detections a zone will exclude.
- Zero zones explainer sits in the rail: "No zones — presence counts the
  whole frame. Draw one to limit presence to part of the picture."
- Sub-stream note (`#zone-aspect-note`, static, whenever a sub URL is
  set): "Zones are drawn on the main stream; detection runs on the sub
  stream. Both must share an aspect ratio or zones land in the wrong
  place." There is no live mismatch card in this round.
- Saved zones use distinct hues per zone (FREE — but do not reuse the label
  palette; zones are not labels). A detection inside two zones counts in
  both; overlapping polygons are normal, not an error.

### Config

- Same page minus the camera cards; the link row to Cameras where they
  were; the import section in Config health. Header sub-copy updated.
  Reload button and result card unchanged.

## States (per page)

**Cameras**
- Empty · rows · rows with `#save-result` (ok: badges + warnings; error:
  mono errors + "Your previous config is still active — nothing changed.")
- Row per status: connecting (pulse) · running · backoff "Unreachable" ·
  stalled · transcode_unavailable · unknown.
- Row per `data-loaded`: loaded · skipped (errors inline) · disabled ·
  unloaded (`#cameras-load-errors` banner carries the reason).
- Row "not probed yet" (no probe result) vs chips vs not-H.264 warning
  chip vs transcode-unavailable danger chip.
- Toggle in flight ("applying", the switch disabled) · toggle refused (the
  loader's strings on the row, switch back where it was).
- Remove confirm (`data-confirm`) → row gone + `removed {id}`.

**Add camera — scan** (`#onvif-scan[data-state]`)
- idle: prompt + Scan network; Add by IP quiet below.
- scanning: button disabled "Scanning…", spinner; the list area shows a
  quiet "Listening for cameras…". Expect ~3 s; if the scan runs past ~10 s
  the wrapper gives up → error.
- done, N found: rows; "added as {id}" rows badged.
- done, none found — name both causes: (a) "No camera answered on this
  interface. Multicast may be blocked, or the camera is on a different
  interface — pick it above and scan again." (b) "…or the camera is on
  another subnet or has ONVIF turned off — add it by IP address." Add by
  IP becomes the primary suggestion; the manual tab is the other.
- error: "The scan didn't finish. Try again, or add the camera by IP."

**Add camera — sign-in modal** (`data-state`, `data-error`)
- idle · connecting ("Connecting…", fields disabled; can take several
  seconds — the camera is asked for its time, identity and services)
- error `unauthorized`: "{name} rejected these credentials." Both fields
  error-bordered; username kept, password cleared. On the Add-by-IP path
  there is no name yet (identity is read only after sign-in succeeds), so
  the copy falls back to the IP.
- error `unreachable`: "Cairn couldn't reach {ip} — the camera answered
  discovery but its ONVIF service isn't responding." Retry / Enter URLs.
- error `timeout`: "{ip} didn't answer in time." Retry.
- error `no_profiles`: "Signed in, but {name} exposes no media profiles
  (Cairn needs ONVIF Media2 or Media1)." → "Enter stream URLs instead"
  switches to the manual tab (FREE whether username/password carry over).

**Add camera — profiles**
- fetching (skeleton cards, "Reading stream profiles…")
- ready with ≥2 profiles (main + sub pre-picked) · ready with 1 profile
  (sub = none; note "This camera exposes one stream; detection and
  recording both use it.") · a profile whose stream URI could not be read
  (card disabled, chip "no stream URI") · main and sub picked the same
  (inline error "Main and sub can't be the same profile") · non-H.264 main
  (warning chip).

**Add camera — probe** (`#probe-main` / `#probe-sub` `data-state`)
- idle (button enabled once a URL is present) · running ("Probing… up to
  15 s") · ok: chips codec / `2560×1440` / `20 fps` / `Main`; warning chip
  "not H.264" with title "Switch the camera to H.264 or enable transcode"
  when the codec is not h264 and transcode is off · error: danger chip
  "Probe failed — {message}" (unreachable, auth refused, timed out after
  15 s, no video stream).

**Add / Edit — save** (`#camera-save`, `#camera-form-errors`,
`#save-result[data-ok][data-phase]`)
- validation failed (instant): field errors inline + the rest in
  `#camera-form-errors`; Save stays enabled.
- applying: form disabled, Save "Saving…", card "Applying — restarting
  {id}…" (can take up to 30 s; the camera's stream drops and returns).
- done ok: badges — new: `added {id}`; edit that changed a restart-class
  value: `restarted {id}`; hot-only edit (including a restart-class
  override typed equal to what the camera already inherited): `updated
  {id}`; remove: `removed {id}`. The badge is the diff's verdict, not the
  form's prediction, so a "restarts camera" chip followed by `updated` is
  a legal pair. When *other* cameras appear as `restarted`, add the
  explainer: "Adding a camera changed the detection ladder rung, so {other}
  restarted too."
  Warnings list (tier-1 track inert, motion_json inert, tier-2 zones
  inert) in warning colour.
- done error: danger card, mono errors, "Your previous config is still
  active — nothing changed." Two causes, same card: the loader refused the
  fleet (another session's save won a race — the form keeps the
  operator's values), or the database write itself failed (rare; the
  message names it).
- After a successful save: a *create* lands on Cameras with the card at
  the top; an *edit* stays on Edit with the card above the form
  (decision 7).

**Edit**
- pristine · dirty (FREE: an "Unsaved changes" chip) · dirty on a restart
  field (the line near Save reads "Saving may restart {id} and clear its
  presence in Home Assistant" — "may", because the resolved compares decide
  at apply time) · unknown id → redirected to Cameras with a
  flash · remove confirm open · removing ("Removing…") → Cameras with
  `removed {id}`.

**Zone editor** (`#zone-editor[data-dirty]`, `#zone-surface[data-ready][data-mode]`)
- waiting (`data-ready="false"`): no frame yet — surface and tools
  disabled, the tile's status badge + message overlay (backoff / stalled /
  transcode-unavailable copy from round one), `#zone-waiting` "Waiting for
  the first frame before you can draw." Renaming and deleting saved zones
  still work.
- ready, `idle`: frame up, saved zones drawn, `#zone-empty` when none.
- ready on Standard transport: picture, no live boxes, `#zone-live-hint`.
- `drawing`: N points placed; Close enabled from 3; Undo point; Cancel;
  the first vertex highlighted when closable (FREE); the ghost rubber band
  from the last vertex to the pointer.
- `closed`: the polygon filled, `#zone-form` shown (name, id), Save zone.
  Editing an existing outline: same, with the id disabled and the row
  marked selected.
- Close refused → `#zone-error`: "A zone needs at least 3 points." ·
  "This outline crosses itself — move a point so the edges don't cross."
- zone form errors (`zone-validate`): "zone id is required ([a-z0-9_-],
  lowercase)" · "zone id {x} is already used on this camera" · name over
  64 chars. Name blank → defaults to the id (FREE).
- dirty (`data-dirty="true"`): a draft exists; leaving the page loses it
  (FREE: `data-confirm` on nav).
- saving: Save "Saving…"; the picture does not blink — zones apply to the
  running camera without a restart.
- saved: `#zone-result` "Zones saved — presence on this camera re-confirms
  within ~2 s; presence in removed or reshaped zones is cleared now." with
  `updated {id}`. On a camera without presence detection `#zone-inert`
  stays visible: "Zones are stored but this camera runs no presence
  detection."
- save error: the loader's strings in `#zone-result`.
- `#zone-notice`: the camera came back at a different resolution — the
  box resized, the draft is intact.
- reconnecting: the layout's "Attempting to reconnect" flash; surface
  greyed. A rejoin restores the draft from the client; a full remount
  loses it. A player that drops and returns goes waiting → ready with the
  draft intact.
- delete confirmation: the browser `data-confirm` ("Delete this zone?
  Presence for it clears.").

**Config**
- unchanged reload states; `#config-import` in its three shapes: imported
  on {date} only · plus "still lists cameras" · plus "changed since
  import" with Re-import; re-import confirm; re-import result in
  `#reload-result`.

## What design must NOT change

- The player contract: `camera-video-{id}-{transport}` id, the conditional
  hook, `phx-update="ignore"`, `data-camera-id`, `data-hls-url`, `muted
  autoplay playsinline`; never set `src` or `srcObject`; never wrap the
  video in something that intercepts its hook; the event names the hooks
  push (`webrtc_active`, `webrtc_inactive`, `transport_failed`) and the
  toggle's `phx-value-transport`.
- On the zone editor, the `<video>`'s inline style as written
  (`position: absolute; inset: 0; width: 100%; height: 100%; object-fit:
  contain`) and the four layout preconditions of the coordinate identity:
  1. `#zone-frame`'s aspect comes from the player's reported dimensions
     (the server sets it); design never hard-codes an aspect on it.
  2. `#zone-frame` has zero padding and zero border.
  3. `#zone-frame` carries no explicit `height`.
  4. `#zone-frame` is not stretched by its parent: `align-self:
     flex-start` in a flex row, `align-items: start` in a grid, when it
     sits beside the rail.
- `#zone-svg`, `#zone-ghost` and the vertex handles stay **descendants** of
  `#zone-surface`; `#zone-overlay` stays its **sibling** with
  `pointer-events: none`; the surface's percent / `viewBox` geometry.
- `phx-update="ignore"` on any element a hook owns (video, canvas,
  `#zone-ghost`) and on nothing else.
- Hook names (`MsePlayer`, `WebrtcPlayer`, `TimelineSeek`, `TrackOverlay`,
  `CopyText`, `ZoneEditor`) and the `data-*` they read.
- The six `data-status` values and the four badge words `added removed
  restarted updated`.
- `#camera-overlay-{id}`: `pointer-events: none`, percent geometry set by
  the server — do not restyle box positions.
- Credential masking: no saved password or token in any `value=`, readout,
  tooltip or placeholder; `•••••` is the mask; the password field is
  write-only everywhere.
- Every `id`, `data-*`, `name=`, `phx-*` and route in the contract blocks.
- Tokens, `hs-*` primitives, Material Symbols only, tabular numerics, the
  dark theme.

## Device / viewport targets

- **Wall tablet**, landscape, 1024–1280 px wide, touch: everything works
  by tap (no hover-only affordances), targets ≥ 44 px, `inputmode` on
  numeric fields, pointer events for the zone surface. The zone stage plus
  its tools fit one screen without the page scrolling under a finger
  mid-draw (decision 3).
- **Laptop**, 1366–1920 px, mouse + keyboard: Enter / Esc / Backspace on
  the zone editor, tab order through the form, `phx-disable-with` states
  visible.
- **Dark only**, as rounds one and two: the root sets `data-theme="dark"`;
  there is no light theme to design.
- Density: this is an operations tool — favour information density over
  whitespace, but keep the form breathable enough to read a threshold
  error next to its cell on a tablet.

## State management (per LiveView)

- **CamerasLive** (`:index | :new | :edit` by `live_action`): `@cameras`
  (the saved rows) overlaid with what the running config made of each
  (`loaded | skipped | disabled`) and `@statuses` (subscribed once
  connected); `@tab` from the URL; `@scan %{state, interface, devices,
  error}`; `@connect %{state, error, device}`; `@profiles %{state, list}`
  and the picked main/sub; `@form` (the camera map as a form; `phx-change`
  validates the whole candidate fleet so cross-field and cross-camera
  errors show live); `@probe %{main, sub}`; `@save_result %{ok, phase,
  diff, warnings, errors}`. Async: scan, connect + profile fetch, probe,
  apply (save, toggle, remove). Client-only: modal open/close, the
  password field's DOM value. The page re-reads its rows when any session
  changes the config.
- **ZonesLive**: `@camera`, `@zones` (saved), `@draft` (`points`,
  `closed?`, `editing`), `@selected`, `@dims` (last known frame dims, kept
  across a player drop), `@ready?` (a frame is on screen now),
  `@transport` (ZonesLive handles the same four player events as the
  dashboard), `@detections` (subscribed), `@error`, `@notice`, `@result`,
  `@dirty?`, `@inert?`. Async: apply. Client-only: pointer → normalized
  conversion, the drag ghost, the reconnect draft restore.
- **ConfigLive**: as today minus `cameras`; plus the import marker and the
  re-import action.
- **DashboardLive**: subscribes to config changes and re-mounts; no
  visible state.

## Data shapes (for realistic mock content)

```jsonc
// Camera (form/edit; what the row shows)
{ "id": "front_door", "enabled": true, "loaded": "loaded",              // loaded | skipped | disabled
  "rtsp_url": "rtsp://admin:•••••@192.168.1.20:554/h264",             // masked on read
  "substream_url": "rtsp://admin:•••••@192.168.1.20:554/h264_sub",
  "plugin": "yard",            // plugin group name from config.yml, or null
  "ingest": "ffmpeg", "transcode": false,
  "min_score": {"default": 0.5, "person": 0.6},
  "track":  {"person": {"min_score": 0.6}},            // null when absent
  "record": {"person": {"min_score": 0.7}, "car": {"min_score": 0.8}},
  "retention_days": null, "retention_per_label": {"person": 30},
  "pre_window_seconds": null, "post_window_seconds": 10, "max_event_seconds": null,
  "annotation_offset_ms": 0, "tracker": null, "max_live_tracks": null,
  "motion_json": null, "extra_ffmpeg_args": [],
  "zones": [{"id": "porch", "name": "Porch", "points": [[0.12,0.55],[0.48,0.52],[0.5,0.98],[0.1,0.98]]}] }

// A skipped row carries the loader's reasons
{ "id": "garage", "enabled": true, "loaded": "skipped",
  "errors": ["unknown plugin \"old_group\" — define it under plugins:"] }

// Status map entry (row badge + chips)
{ "status": "running", "probe": {"codec": "h264", "width": 2560, "height": 1440, "fps": 20.0, "profile": "Main"} }
{ "status": "backoff", "probe": {"error": "connection refused"} }

// Import marker (Config health)
{ "path": "/config/config.yml", "sha256": "…", "imported_at": "2026-09-02T21:31:07Z" }

// ONVIF device (scan row)
{ "name": "Front Door", "model": "IPC-HDW2431T", "ip": "192.168.1.20", "address": "http://192.168.1.20:80/onvif/device_service", "added_as": null }

// ONVIF profile (profiles card)
{ "token": "Profile_1", "name": "MainStream", "width": 2560, "height": 1440, "fps": 20, "codec": "H.264", "bitrate": 4096,
  "uri": "rtsp://192.168.1.20:554/cam/realmonitor?channel=1&subtype=0" }

// Save result (card)
{ "ok": true, "phase": "done",
  "diff": {"added": ["front_door"], "removed": [], "changed": ["back_yard"], "refreshed": []},
  "warnings": ["camera back_yard: track: has no effect at tier 1 — …"], "errors": [] }
{ "ok": false, "phase": "done", "diff": null, "warnings": [],
  "errors": ["camera front_door: record.person (0.5) must be >= track.person (0.6)"] }
```

## Decisions on the open questions

The eight questions the earlier drafts asked, now decided. Push back in
the README if one of them fights the design; otherwise build on them.

1. **Nav.** Five items: Dashboard · Events · Tracks · **Cameras** · Config,
   in that order. Cameras uses the `video_settings` glyph (`videocam` stays
   with Dashboard). Config keeps `tune`.
2. **Reaching the editors from the dashboard.** The tile's `<h2>` becomes a
   link to `/cameras/:id/edit`. No per-tile Zones affordance — the
   dashboard stays glanceable; Cameras is the door to zones.
3. **Zone editor on the tablet.** Side rail on the landscape tablet too;
   the stage shrinks by its width rule so frame plus toolbar fit one
   screen. No bottom sheet in v1. Vertex handles are 28 px hit targets;
   the visible dot is yours.
4. **Signalling "restarts camera".** A combination: a small chip in the
   label row of every restart-class field (the `data-restart="true"`
   wrapper is what production marks), plus the one line next to Save that
   appears only while a restart field is dirty. No section-level header —
   the Stream group is mostly restart-class but not entirely.
5. **The "excluded" blank cell.** An explicit `excluded` pill in the cell
   (warning badge, sm) with a title explaining why. Ghost numbers mean
   "inherits"; a pill means "gets nothing".
6. **Self-intersecting polygon.** Blocked at Close with an inline error.
   Overlapping *zones* stay allowed.
7. **After Save.** A create lands on Cameras with the result card at the
   top; an edit stays on Edit with the card above the form, because the
   operator tuning thresholds saves several times in a row. Toggle and
   Remove render their card on Cameras.
8. **"Already added" matching.** Host only. A scanned device whose host
   backs a saved camera on a different port or path shows "added as {id}"
   and keeps Add enabled — one host can carry two channels.

## Files (expected back)

- Prototype HTML for `/cameras` (empty, rows, rows with a result card,
  a skipped row, a disabled row), `/cameras/new` (both tabs, the sign-in
  modal, the profiles step, the prefilled form), `/cameras/:id/edit` (with
  the remove modal), `/cameras/:id/zones` (waiting, idle, drawing, closed
  with the form, saved), and the updated `/config` (with the import
  section in each of its shapes).
- Any `hs/shared.css` additions, clearly separated from the round-one
  sheet.
- A README listing every new Material Symbols glyph name used, and any of
  the eight decisions the design argues with.
