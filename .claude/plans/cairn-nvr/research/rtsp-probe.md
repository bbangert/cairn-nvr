# RTSP DESCRIBE Codec Probe — Library Research

## Context

Cairn needs a one-shot probe at camera-add/config-reload time: connect to an RTSP
camera, send DESCRIBE (with Basic/Digest auth), parse the SDP, and report video
codec (H.264/HEVC/MJPEG), resolution if present, and audio codec — purely to warn
users before ffmpeg starts the real ingest. No streaming, no RTP, no long-lived
connection required.

## Option 1: `membrane_rtsp` standalone

- **Hex**: https://hex.pm/packages/membrane_rtsp — v0.12.1, released 2026-06-29
  (actively maintained; release cadence roughly every 1–4 months through 2024–2026)
- **Docs**: https://hexdocs.pm/membrane_rtsp
- **Downloads**: ~70.6k all-time, ~1.1k/week — healthy for a niche protocol library
- **Dependency tree**: `bunch` (~1.6), `ex_sdp` (~0.17/~1.0), `nimble_parsec` (~1.4),
  `mockery` (~2.3, dev/test only in practice). **No `membrane_core` dependency.**
  This confirms it works standalone — the RTSP client (`lib/membrane_rtsp/rtsp.ex`)
  is a self-contained GenServer-free session process talking raw TCP, independent
  of the Membrane pipeline/element framework. Total added deps are small (4
  packages, none of them heavy).
- **API**: `Membrane.RTSP.start_link(url, options)` opens a session process;
  `Membrane.RTSP.describe(session, headers \\ [])` sends DESCRIBE and returns
  `{:ok, %Membrane.RTSP.Response{}}` with `.body` containing the raw SDP text and
  `.headers`/`.status`. Feed `.body` to `ExSDP.parse/1` to get a structured
  `%ExSDP{}` with a `media` list, each entry having `type: :video | :audio`,
  RTPMapping (encoding name e.g. `"H264"`, `"H265"`, `"JPEG"`, `"PCMA"`, `"MPEG4-GENERIC"`),
  clock rate, and fmtp attributes. Resolution is *not* reliably present in SDP for
  RTP/H.264 streams (it's negotiated in-band via SPS, not SDP) — expect to get it
  only when cameras include vendor-specific `a=x-dimensions` or similar, which is
  inconsistent. For MJPEG some cameras include dimensions in the fmtp line.
- **Auth**: Read directly from source (`lib/membrane_rtsp/rtsp.ex`). Credentials
  come from the URI's userinfo (`rtsp://user:pass@host/...`). The client optimistically
  tries Basic first if userinfo is present, and on a 401 with a `WWW-Authenticate:
  Digest ...` header, `detect_authentication_type/2` parses `nonce`/`realm`/`qop`
  from the challenge and transparently retries with a correctly computed Digest
  header (`encode_digest/4`, handling both qop and no-qop RFC 2617/7616 variants,
  with nonce-count tracking across requests). This is exactly the auth flow needed
  and appears well-tested — GitHub issue #58 ("Add RFC 2617 qop support and fix
  SETUP URL handling") shows the maintainers actively fixed qop-based digest auth.
- **Known issues**: open issue #51 ("Support for TCP transport (interleaving)",
  since 2025-02-25) — but that's about RTP-over-TCP for actual streaming (SETUP/PLAY),
  irrelevant to a DESCRIBE-only probe which never opens a media transport.
- **GitHub**: https://github.com/membraneframework/membrane_rtsp — maintained by
  Software Mansion / Membrane team, same org behind `ex_sdp`; low open-issue count,
  responsive maintainers.

## Option 2: Shell out to `ffprobe -show_streams -of json`

- No extra dep — Cairn already depends on ffmpeg for ingest, so ffprobe is present
  on the same binary/container image with guaranteed version parity to the ingest
  path (same RTSP/TLS/auth stack, same codec table, same quirky-camera compatibility
  as whatever will actually stream the video).
- Command shape: `ffprobe -v quiet -print_format json -show_streams -rtsp_transport tcp -timeout <us> rtsp://user:pass@host/path`.
  JSON output parses trivially into codec_name, codec_type, width, height, etc. —
  actually *better* resolution data than SDP-only inspection, since ffprobe reads
  the actual bitstream (SPS/PPS for H.264, first JPEG frame for MJPEG) rather than
  relying on SDP attributes that cameras may omit.
- Subprocess cost: one `System.cmd/3` (or `Port`) invocation per probe, at
  camera-add/config-reload time only — not a hot path, so process-spawn overhead
  (tens of ms) is a non-issue.
- Timeout control: `-timeout` (microseconds, applies to the RTSP TCP connection)
  plus wrapping in `System.cmd(..., [timeout: ...])`-style external kill via `Port`
  with a `Process.send_after` kill, since `System.cmd/3` itself has no built-in
  timeout option in OTP — needs a small wrapper (e.g. `Task.await` with `Task.Supervisor.async_nolink` + `Task.yield`/`shutdown`, or a `Port` and manual `Port.close/1` on timeout).
- Auth: embed credentials in URL (works for Basic and, since recent ffmpeg
  versions, transparently negotiates Digest too) — same as membrane_rtsp,
  effectively delegates the whole auth dance to ffmpeg's libavformat RTSP demuxer,
  which is the most battle-tested implementation of the three options against
  real-world camera firmware quirks.
- Downside: couples the probe to ffmpeg's exit-code/stderr conventions instead of
  clean `{:ok, _} | {:error, _}` tuples; a hung or non-responsive camera can leave
  a zombie ffprobe process if timeout/kill handling is sloppy; JSON parsing needs
  `Jason` (already a Phoenix dependency, no new cost). ffprobe with `-show_streams`
  on some cameras still triggers a brief SETUP/PLAY (a few packets) rather than a
  pure DESCRIBE-only exchange, depending on ffmpeg version and flags — meaning it
  is not strictly equivalent in protocol footprint to a DESCRIBE-only probe (may
  briefly open a UDP/TCP media session even though `-show_streams` is meant to be
  metadata-only).

## Option 3: Hand-rolled DESCRIBE + `ex_sdp`

- **ex_sdp**: https://hex.pm/packages/ex_sdp — v1.1.4, released 2026-07-01 (i.e.
  updated this week relative to "today"), ~standalone parser (no Membrane core
  dependency per docs/readme), built on `nimble_parsec`. This is the same SDP
  parser membrane_rtsp itself uses, so choosing option 3 doesn't avoid it — it
  only avoids the RTSP transport/auth layer.
- Effort estimate for the RTSP+auth part that would need to be reimplemented:
  - Raw TCP connect + write `DESCRIBE rtsp://... RTSP/1.0\r\nCSeq: 1\r\n...\r\n\r\n`,
    read the response, split status line/headers/body — genuinely small, an
    afternoon of work for the happy path.
  - Basic auth: trivial, one line (`Base.encode64/1`).
  - Digest auth (RFC 7616/2617): non-trivial correctness surface — must parse the
    `WWW-Authenticate` challenge (realm, nonce, opaque, qop, algorithm — including
    handling `algorithm=MD5-sess` variants some NVR-oriented cameras use), compute
    HA1/HA2 MD5 hashes, track/increment nonce-count (`nc`) across requests within
    a session, handle `qop=auth` vs absent qop vs comma-separated qop lists
    (`qop="auth,auth-int"`), and handle stale-nonce retry (`stale=true` triggering
    a fresh challenge rather than a hard failure). This is exactly the class of
    "looks small, has a long tail of camera-firmware-specific edge cases" work —
    realistically 1–2 days to get right plus camera-specific bug reports over
    time, essentially re-deriving what membrane_rtsp's `encode_digest`/
    `detect_authentication_type` already do and have already been bug-fixed
    against (see issue #58 above).
  - Redirect handling (RTSP 3xx) and multi-line/obscure header folding are further
    edge cases a hand-rolled client would need to grow over time as real cameras
    are encountered.
  - Net: hand-rolling saves ~4 small dependencies but reimplements a solved,
    already-battle-tested piece of protocol logic (Digest auth) for no functional
    gain, since ex_sdp would be a dependency either way.

## Thesis / Antithesis

### membrane_rtsp (+ ex_sdp transitively)

- **Thesis**: Purpose-built, small dependency footprint (no membrane_core),
  actively maintained by a serious Elixir shop, handles the one genuinely fiddly
  part (Digest auth with qop/nc) correctly and with git history showing real bug
  fixes against it. Returns clean Elixir data structures (`%Response{}`, `%ExSDP{}`)
  with tagged-tuple results — idiomatic, no subprocess/JSON boundary, no zombie
  process risk, easy to unit test with a fake TCP listener.
- **Antithesis**: A second, independent RTSP client implementation from the one
  ffmpeg actually uses for ingest — so a camera whose DESCRIBE response
  membrane_rtsp can't parse (nonstandard SDP, weird auth variant, TCP quirk) could
  pass probing yet still work fine with ffmpeg, or vice versa: probe succeeds but
  ffmpeg's ingest still fails for unrelated reasons (SETUP/PLAY-stage issues the
  DESCRIBE-only probe never exercises). Also does not reliably surface resolution
  (SDP frequently omits it for H.264/HEVC), so "resolution if present" will often
  be absent — probe may need to fall back to a short ffprobe call anyway for that
  field specifically, undermining the "avoid ffprobe" motivation somewhat. Open
  issue #51 (no TCP/interleaved transport) is irrelevant to DESCRIBE but signals
  the library's SETUP/PLAY path is less mature — a reminder this project is closer
  to "actively developed" than "rock solid legacy," so mid-2026 dependency-update
  churn is possible.

### Shell out to ffprobe

- **Thesis**: Zero new dependency, and — critically — uses the *exact* RTSP/TLS/
  auth/codec stack (libavformat) that will actually perform the ingest, so a
  successful probe is a much stronger signal that ingest will also succeed
  (same failure modes, same camera-compatibility quirks already known/handled by
  ffmpeg upstream). Gets resolution reliably (reads actual bitstream, not just
  SDP), which the pure-SDP approaches often can't. JSON output is trivial to
  parse with the already-present Jason dependency.
- **Antithesis**: Introduces subprocess-management complexity (timeout/kill
  semantics, zombie-process risk, exit-code/stderr parsing instead of clean
  `{:ok,_}/{:error,_}`) into what is meant to be a lightweight, fast, in-process
  check. Cost of spinning a full OS process for what is conceptually a handful of
  TCP packets is real, if not large, at camera-add time (and multiplies if probing
  is ever done for many cameras concurrently, e.g. bulk import or periodic
  re-validation of a large camera fleet). `-show_streams` semantics can, depending
  on flags/ffmpeg version, do more than a bare DESCRIBE (may briefly negotiate
  SETUP), so it's not strictly a "read-only" DESCRIBE probe. Failure messages are
  opaque stderr text requiring fragile string-matching to distinguish "wrong
  credentials" from "camera unreachable" from "unsupported codec," where
  membrane_rtsp would give a typed RTSP status code.

### Hand-rolled DESCRIBE + ex_sdp

- **Thesis**: Full control over exactly what's sent/parsed, minimal dependency
  surface beyond `ex_sdp` (which is needed regardless), and a straightforward
  mental model — no subprocess, no membrane_rtsp abstractions to learn if the team
  only ever needs DESCRIBE and never SETUP/PLAY. Easiest to keep small and
  auditable long-term for a probe-only use case.
- **Antithesis**: Digest auth (RFC 7616, qop/nc/stale handling, algorithm
  variants) is a well-known "simple until it isn't" protocol detail with a long
  tail of camera-firmware-specific bugs; reimplementing it duplicates work
  membrane_rtsp has already done and iterated on (see issue #58). Realistic
  effort is measured in days plus an ongoing maintenance burden as new camera
  models surface auth edge cases, for a saving of only ~3 small transitive
  dependencies (bunch, nimble_parsec, mockery) versus depending on membrane_rtsp
  directly. Team also still needs to wrap the socket code behind a project-owned
  facade (Iron Law: wrap third-party/hand-rolled protocol code) — so the
  "simplicity" gain over membrane_rtsp is mostly illusory once auth is factored in.

## Sources

- https://hex.pm/packages/membrane_rtsp (downloads, release history)
- https://hex.pm/api/packages/membrane_rtsp/releases/0.12.1 (dependency requirements)
- https://hexdocs.pm/membrane_rtsp
- https://github.com/membraneframework/membrane_rtsp (source: `lib/membrane_rtsp/rtsp.ex`,
  auth implementation, issues #51 and #58)
- https://hex.pm/packages/ex_sdp (downloads, release history)
- https://ex-sdp.hexdocs.pm/readme.html
- ffmpeg/ffprobe `-show_streams`, `-timeout`, `-rtsp_transport` documented behavior
  (general ffmpeg RTSP demuxer knowledge; no dedicated hex.pm page since it is an
  external binary, not an Elixir library)
