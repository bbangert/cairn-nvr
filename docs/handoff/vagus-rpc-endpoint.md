# HANDOFF: board-side RPC endpoint for the HTP campaign driver

**STATUS: LANDED.** Vagus PR bbangert/vagus#34 shipped `Vagus.Dist` —
option A, with one deliberate deviation from the sketch below:
distribution is **off by default and enabled per boot** over ssh
(`Vagus.Dist.enable()` mints a fresh cookie and returns
`{:ok, %{node:, cookie:, ports: 9100..9105}}`; a reboot is the only off
switch), rather than always-on with a cookie file under `/data`. All
seven acceptance criteria validated on .87, 2026-08-26. The consumer is
`tools/qdq-export/driver/` (`Driver.Board` implements this contract;
`Driver.Campaign` is the ported campaign). The rest of this document is
the original ask, kept for the rationale and the contract details.

Audience: the Vagus development agent (board firmware, QCS6490 host at
192.168.2.87). Origin: cairn-nvr PR #143 (`tools/qdq-export` refactor),
where eighteen review rounds hardened a workaround protocol that this
endpoint makes unnecessary.

## Why

The cairn-nvr HTP verification campaign (`tools/qdq-export/
run_htp_campaign.sh`) drives the board from Ben's dev container over
nerves_ssh. That transport lies twice:

1. **Exit codes vanish.** The ssh exec channel evaluates Elixir; commands
   ride `:os.cmd(~c|...|)`, which swallows the command's rc and forbids
   literal `|` (the sigil terminator). Every board read reconstructs
   success by writing output to a tmp file, appending a per-call nonce to
   a separate `.ok` file gated on `&&`, fetching both, and comparing a
   recorded sha256 of the payload (`remote_verified()` in the driver).
2. **Transfers can't prove completeness.** scp over this transport exits
   1 even on success, so `fetch()` checks only that a destination
   exists — a partial transfer is indistinguishable from a complete one
   without the digest protocol above.

An RPC endpoint on the host BEAM deletes both problems at the root:
`System.cmd` returns `{output, exit_status}` as a term, and
`File.read/1` returns `{:ok, binary}` whole-or-error by construction.

## What we know about the board (verified from the driver side)

- A host-level BEAM node (the one serving nerves_ssh) **survives
  stopping the cairn addon container** — verified across many campaigns:
  ssh keeps answering and can run `balena-engine stop/start
  addon_c2da371c_cairn` while the addon is down. That node is the RPC
  target; the campaign runs with the addon stopped (it holds the NPU).
- Persistent storage at `/data` (survives reboot); busybox userland;
  `sh`, `sha256sum`, `balena-engine`, sysfs cpufreq all present.
- Campaigns reboot the board deliberately (CDSP session-leak recovery,
  ~18-session budget), so the endpoint must come back up unattended.

## The ask (option A — preferred): enable Erlang distribution

No API surface is required. Everything the driver needs is stdlib on a
distributed node:

1. Start the host node distributed: longname with the IP (no DNS on the
   LAN), e.g. `vagus@192.168.2.87`.
2. Provision a cookie the driver can read: a file under `/data` (e.g.
   `/data/vagus.cookie`, mode 0600) or document wherever Vagus keeps it.
   Ben's dev container will read the same value.
3. Pin the distribution listen range so it's firewallable:
   `inet_dist_listen_min`/`inet_dist_listen_max` (suggest 9100–9105),
   plus epmd on 4369. LAN-only exposure; cookie auth is the accepted
   posture for now (TLS distribution is a possible later hardening, not
   part of this ask).
4. Ensure it starts on boot with no manual step — campaigns reboot the
   board mid-run and reconnect.

Optional nicety, not required: a tiny `Vagus.Campaign` module with a
chunked file-write helper (`append/2` in 1–4 MB chunks) for pushing
ONNX artifacts (12 files, ~5–40 MB each). Plain `File.write/3` with
`[:append]` via `:erpc` works; a helper just keeps single messages
small. Fetching evidence needs nothing: the files are small
(ndjson/meta, a few MB) and `File.read/1` is already whole-or-error.

## Option B (fallback, weaker): real ssh exec channel

If distribution is unacceptable, configure nerves_ssh's exec to run
`sh -c` with the real exit status returned on the channel, and confirm
the SFTP subsystem's per-operation error semantics. This fixes exec rc
but keeps ssh transfer semantics; option A is strictly better and no
harder.

## What the driver will call (consumption contract to validate against)

```elixir
# run the sha-pinned on-board test script, real rc at last:
:erpc.call(node, System, :cmd,
  ["sh", ["-c", "PROFILE=yolox INSIZE=416 sh /data/cairn-bench/htp_content_test.sh ..."],
   [stderr_to_stdout: true]], 420_000)
# whole-or-error evidence fetch:
:erpc.call(node, File, :read, ["/data/cairn-bench/content/<tag>/meta"])
# governor, engine control, reboot coordination:
:erpc.call(node, System, :cmd, ["sh", ["-c", "balena-engine stop addon_c2da371c_cairn"]], 90_000)
:erpc.call(node, File, :read, ["/proc/sys/kernel/random/boot_id"])
```

Long calls matter: content runs take up to ~7 minutes; the driver passes
explicit `:erpc` timeouts. Reboot detection will use
`:net_kernel.monitor_nodes/1` (nodedown/nodeup) plus a boot_id read as
the "actually rebooted" witness.

## Acceptance criteria (testable from any LAN peer)

From a distributed peer node with the cookie:

1. `Node.connect(:"vagus@192.168.2.87")` → `true`.
2. `:erpc.call(node, System, :cmd, ["sh", ["-c", "echo hi; exit 3"], [stderr_to_stdout: true]])`
   → `{"hi\n", 3}` — the exit status is the whole point.
3. `:erpc.call(node, File, :read, ["/data/<some file>"])` → `{:ok, bin}`
   with `:crypto.hash(:sha256, bin)` matching board-side `sha256sum`.
4. Connection survives `balena-engine stop/start` of the cairn addon.
5. After `reboot`: nodedown observed, node reconnectable without manual
   intervention, boot_id changed.
6. A 60 s sleep command under a 90 s `:erpc` timeout completes; the same
   under a 10 s timeout raises on the caller without wedging the node.
7. Distribution ports confined to the documented range (verify with
   `ss`/netstat on the host).

## Non-goals / constraints

- Do not touch the cairn addon container or its runtime contract.
- `htp_content_test.sh` stays a busybox `sh` script pushed by the
  campaign (its sha is the methodology digest) — the endpoint only needs
  to exec it and report the truth.
- nerves_ssh stays as-is for interactive access; this is additive.
- LAN-only. Nothing here should be reachable beyond Ben's network.

## What happens on the cairn-nvr side once this lands

The campaign driver gets ported off bash (an Elixir mix task or a
Python/Fabric driver was also considered; with this endpoint the Elixir
route is the natural fit). The `remote_verified` nonce/digest protocol,
the boot-id dance, and the partial-transfer guards all collapse into
plain calls with real return values. The retry-guard and analyzer
(`campaign_meta.py`, `htp_report.py`, 80-test suite) are unaffected —
they consume fetched files and don't care how the bytes arrived.

Questions or changes to the contract: coordinate through Ben (the
campaign driver consumes whatever name/cookie/port conventions Vagus
documents — the specific values above are suggestions, not requirements).
