---
name: code-review
description: Reviews Elixir and Erlang changes in this repository against the principles of Designing Elixir Systems with OTP — process boundaries, single ownership of state, supervision trees that express restart characteristics, and let-it-crash recovery. Use when reviewing any pull request that touches lib/, test/, or config/ in this Elixir/Phoenix/OTP application, especially GenServers, Supervisors, Registry, ETS, PubSub, Membrane pipelines, or process lifecycle.
---

# Reviewing OTP code in this repository

This is a single-node NVR run by one operator. It has no cluster, no
multi-tenant contention, and at most one person using the UI. Judge every
concern against that: a race that needs two operators or two nodes to occur
does not occur here, and a fix that adds coordination to prevent it is a
regression in design. The bar is the one in *Designing Elixir Systems with
OTP*: data, then functions, then tests, then boundaries, then lifecycles,
then workers. A finding is worth raising when the code puts something in the
wrong layer, not when it could theoretically be made more defensive.

## What the tree is, and what it must stay

Each camera is a supervision tree under `Cairn.CameraSupervisor`:
`Cairn.Camera` (`:one_for_one`) over `:media` (`:rest_for_one`: probe, ring
buffer, optional ffmpeg port, pipeline owner, RTP hub) and then `:lane`
(`:one_for_one`: the event workers the camera's tier selects). Event
extractors are `:temporary` under `Cairn.EventSupervisor` and owned by the
lane worker that opened them. Node-level ETS tables (checkpoints, ledger,
status, control) are owned by one process each and outlived by their callers.
`docs/architecture.md` states every reason; the design record is in
`.claude/plans/ui-camera-config/design-supervision.md` when present.

The tree is the authority over process lifetime. A process's restart
characteristics are expressed by where it sits and which strategy its parent
uses, not by another process deciding for it. Strategy follows dependency:
`:rest_for_one` where a child cannot work without the one before it,
`:one_for_one` where children are independent, child order chosen for what
must exist first at start and, in reverse, what must close first at stop.

## Flag these — they are the defects this codebase has actually shipped

Each of these was found in review of a real pull request here. Look for the
class, not the instance.

- **A synchronous call from `init/1` or a restore path back to the process
  that is starting the tree.** A config reload starts camera trees from
  inside `Cairn.Config.Server`'s own `handle_call`, so any child whose init
  calls that server waits on a server waiting on it: a timeout per camera,
  spent inside the operator's save. Config must come from the published
  `:persistent_term` snapshot or from the arguments the tree passed in. The
  same applies one level down: a process started from init that itself calls
  the server (an extractor started without a `config:`) is the same deadlock
  through a second door.
- **A worker that dies with a table it does not own.** Lane workers outlive
  the node-level checkpoint and ledger tables, which have no heir. A bare
  `:ets` call on a missing table raises; a `GenServer.call` to a restarting
  owner exits. If a worker's restore path reads such a table, the failure is
  a child failing to start, which escalates through the lane's and then the
  camera's intensity and bounces the RTSP session. The table's API must read
  a missing table as empty and drop a write to an absent owner.
- **An assumption that a subscription survives a replacement.** A media
  replacement destroys the ring buffer and its subscriber map; a reconnect
  does not, because the ring sits ahead of the pipeline. An extractor that
  subscribed once and holds no monitor starves. The dependency must be a
  monitor, and the process that detects the loss must report to its owner,
  not close on its own.
- **The wrong process closing a clip.** The owner has been updating the
  event's labels, scores and trigger since it opened; the extractor's copy is
  the opening snapshot. A close from anywhere but the owner persists stale
  metadata and skips the lifecycle broadcast. Only an orphan (owner dead)
  closes itself, and then it must broadcast, because nothing else will.
- **Per-pair message ordering broken.** Boxes and the finalize that ends a
  clip must be cast by the same process to the same process, so the BEAM's
  ordering keeps every box ahead of the finalize. Routing the finalize
  through another process, or turning it into a call, silently truncates the
  sidecar.
- **A refresh reaching an open event.** A policy change applies to the next
  event; an in-flight event keeps the windows it opened with. Arming a timer
  from `state.policy` at clear time instead of from an event-scoped copy is
  the bug, and a test that fires the timer by hand cannot see it.
- **A held struct that is passed onward.** A worker that keeps the camera
  and config it was started with, then passes that config into every process
  it starts, must be refreshed on every change class that can reach it, not
  only the "refresh" class. Look for what the held value flows into.
- **Child order that makes the stop lie.** Reverse-order shutdown decides
  which teardown message arrives first. If the media stops before the lane,
  its stop epoch ends every track as a stream reset before the lane's own
  close can label them honestly. The side that must close first goes last in
  the child list.
- **A read-path Registry lookup treated as liveness.** `Registry.whereis`
  can return a dead pid until the partition processes its DOWN. A gate on a
  name must also check `Process.alive?/1`. The register path is different:
  a unique `Registry.register` evicts a dead holder and retries, so a
  terminate-then-start of a named child needs no wait.
- **A comment that declares a case impossible.** Comments here are paired
  with the code after every refactor; the ones asserting a guarantee ("can
  never", "the only caller", "already announced") are the ones most often
  false and most often hiding a defect. Check the claim against the code, not
  the diff.
- **A test that passes in both states.** A test added to pin a fix must fail
  without it. Prefer real processes and timers over stubs and manual timer
  firing when the thing under test is ordering or a duration. Tests use
  monitors, `assert_receive`, and `:sys.get_state/1` barriers, never
  `Process.sleep` polling, and any test starting a real extractor needs the
  shared-mode sandbox, its own temp directory, and to await the extractor's
  DOWN before cleanup.

## Do not suggest these — they were proposed here and were wrong

- **A reaper, reconciler, or stop-time sweep** that reaches across trees to
  end workers, drain rows, or "reconcile" after a crash. That is imperative
  teardown. Disable and delete are tree stops; each worker closes its own
  resources in `terminate/2`; a crash restores from the checkpoint. A worker
  crashing at the exact instant its camera is removed is a double fault whose
  bounded residue is documented, not a reason for an orchestrator.
- **An explicit "config stop" signal** so a worker can tell a config-driven
  stop from a supervisor's restart. A supervisor's `:shutdown` is the stop
  signal; finalizing on it leaves finalized rows instead of stranded active
  ones, and an ancestor giving up after its intensity is spent is a crash
  loop past its budget where a clean clip beats a stuck event.
- **Acknowledged or atomic handoffs** (a call in place of a cast) to close a
  window that message ordering does not close anyway. Ask whether the
  outcome inside the window is already honest before adding a rendezvous.
- **Waits on Registry unregistration before a start**, or claims that
  `Supervisor.terminate_child/2` on an already-down child fails. It returns
  `:ok` for a running, down, or restarting child; `{:error, :not_found}` only
  when no spec exists, so terminate, delete, start cannot hit
  `:already_present`.
- **Timeouts on `GenServer.start_link` from init**, or `Process.exit` on a
  possibly-dead pid needing a guard. A start's `:timeout` option defaults to
  `:infinity` — the 5 000 ms that comes to mind is `GenServer.call/3`'s
  default, a different function — and exiting a dead pid returns `true`.
  Both were asserted otherwise in review here and shown false by running
  them.
- **Multi-node, clustering, or distributed-consistency concerns.** One node
  by design; `DNSCluster` is generator boilerplate.
- **PubSub-restart resilience helpers** (monitor the PubSub, resubscribe,
  reconcile). The design declines this on purpose: a PubSub crash is a
  node-level fault, and hardening every subscriber against it was the
  over-engineering that got the previous approach parked.

## How to write the finding

Name the layer the code violates (boundary, lifecycle, ownership, ordering)
and give the concrete sequence: which process sends what to whom, in what
order, and what the operator then sees. A finding that cannot be stated as a
sequence is a preference, and preferences are not raised here. When the
correct fix is structural — a child order, a strategy, an owner — say that,
rather than proposing a guard that papers over it. When a claim depends on
OTP semantics, state the semantic and expect it to be checked against the
runtime, because several confident claims here were false and were declined
with a reproduction.
