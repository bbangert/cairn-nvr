# Scratchpad: multiplexed-plugin

Decisions, dead-ends, and mid-work notes. Keep plan.md clean; dump here.

## Decisions log

- 2026-07-25 (planning): single-token `plugin:` string = group reference,
  error if undefined; list form is the inline escape hatch. Rejected
  "fallback to inline when no group matches" — turns typos into silent
  spawn crash loops instead of config errors.
- 2026-07-25 (planning): no per-group wrapper Supervisor —
  PluginGroupPort sits directly under the DynamicSupervisor (single
  process per group).
- 2026-07-25 (planning): interview's "group sees RTP silence and resyncs"
  requires a cairn-detect change — current rtp.rs 30s timeout /
  12-attempt open give-up would crash-loop the group when one member
  camera is stopped. Multiplexed mode: per-stream eternal re-open loop
  (T14). Single-camera mode unchanged.
- 2026-07-25 (planning): group diff applied before camera diff on reload;
  strict interleave not load-bearing (UDP handshake-free).

## Dead-ends

(none yet)

## Notes for implementation

- User (2026-07-25): second live camera feed available at
  `rtsp://192.168.2.31:554/s0` — use for the 2-camera live run the plan's
  self-check #3 wants before merging Phase 4.
- 2026-07-25 DONE: live 2-camera e2e ran clean (one group process, both
  real feeds decoding, no routing warnings). Plan complete 17/17.
- 2026-07-25 review: REQUIRES CHANGES → fixed B1 (stale group routes on
  reload → refresh cast), B2 (vacuous wait_new_pid assertion), W1 (drop-log
  throttle), W2 (latest-wins slots via SampleSink; capacity-2 rejected for
  ~5MB/camera memory, cloned-Receiver rejected for breaking Disconnected
  liveness). Verdict now PASS WITH WARNINGS; W3–W6 + suggestions open in
  reviews/multiplexed-plugin-review.md (UDP rebind race, CPU saturation
  at 4+ cams, 60-70s dark-camera reopen latency, coverage gaps).
- Follow-ups spotted during work (not in this plan): (1) orphaned test
  clips can crash next run's Boot reconciliation — pre-existing repo-wide
  hazard, integration tests now clean up after themselves; (2)
  config.example.yml has no `plugins:` example and its plugin comment
  predates the single-token=group-name rule; (3) docs/architecture.md
  still describes strictly one-process-per-camera inference.

- `Config.PluginGroup.members` must be resolved in **config order** of
  cameras (global index → ports) so struct `!=` diffing is deterministic.
- `:start_cameras` app-env gate must also gate PluginGroupSupervisor.sync
  or the test suite will spawn real group processes.
- config_live.ex:111 uses `Enum.join(cam.plugin, " ")` — crashes on tagged
  tuples if forgotten (T3 covers it; grep in T17 double-checks).
