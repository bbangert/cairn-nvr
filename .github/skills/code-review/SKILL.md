---
name: code-review
description: Reviews Elixir and Erlang changes against the principles of Designing Elixir Systems with OTP — process boundaries, single ownership of state, supervision trees that express restart characteristics, and let-it-crash recovery. Use when reviewing any pull request in an Elixir, Erlang, Phoenix, or OTP project, especially changes to GenServers, Supervisors, Registry, ETS, PubSub, Tasks, or process lifecycle.
---

# Reviewing OTP code

The bar is the layering in *Designing Elixir Systems with OTP*: data, then
functions, then tests, then boundaries, then lifecycles, then workers. A
finding is worth raising when the code puts something in the wrong layer —
state without one owner, a lifecycle managed from outside the tree, a
boundary crossed by a call that should be a message — not when it could be
made more defensive. Judge every concern against the project's stated
deployment shape: a race that needs a second node, a second tenant, or a
second operator does not occur in a system that has none, and a fix that adds
coordination to prevent it is a regression in design.

## The tree is the authority over process lifetime

A process's restart characteristics are expressed by where it sits in the
supervision tree and which strategy its parent uses, not by another process
deciding for it. Strategy follows dependency: `:rest_for_one` where a child
cannot work without the one before it, `:one_for_one` where children are
independent, `:one_for_all` only where they share state that cannot be
rebuilt piecemeal. Child order is chosen twice over: for what must exist
first at start, and — since shutdown runs in reverse — for what must close
first at stop. If the design needs a retry, a stash, a reconcile-on-restart,
or a process that reaches across trees to end things, the ownership or the
tree shape is wrong; fix that rather than adding the mechanism.

## Flag these classes

Look for the class, not the instance. Each is a defect that has shipped in
real OTP systems and survived unit tests.

- **A synchronous call from `init/1`, or from anything it runs, back to the
  process that is starting the tree.** A supervisor started from inside a
  GenServer's `handle_call` (a config server applying a change, a
  coordinator reconciling) starts children whose init may call that same
  server, which is waiting on the start: a timeout per child, spent inside
  the caller's request. Config must reach a child through its start
  arguments or a snapshot in `:persistent_term` or ETS, never a call to its
  starter. The same rule applies one level down, to any process the child
  starts from its own init.
- **A worker that dies with a table or process it does not own.** When
  workers outlive the owner of an ETS table (no heir) or a named GenServer
  they write to, a bare `:ets` call on the missing table raises and a call
  to the absent name exits. If that read sits on a restore path in `init/1`,
  the failure is a child failing to start, which escalates through every
  supervisor above it. The owner's API should read a missing table as empty
  and drop a write to an absent owner, and say so in its contract.
- **A subscription assumed to survive the replacement of what it subscribed
  to.** A subscriber list lives in the state of the process that holds it;
  a restarted or replaced holder has never heard of the subscriber. The
  dependency must be a monitor, and the process that detects the loss must
  report to whoever owns the outcome rather than act on a stale snapshot.
- **The wrong process closing a resource.** The process that has been
  updating a record since it opened holds the current metadata; a helper
  holding the opening snapshot does not. A close from anywhere but the owner
  persists stale data and skips the owner's lifecycle notifications. Only an
  orphan — owner dead — may close itself, and then it must emit what the
  owner would have.
- **Message ordering relied on across a pair the messages do not share.**
  The BEAM orders messages between one sender and one receiver. Two casts
  that must arrive in order (data, then the finalize that ends it) must
  leave the same process for the same process; routing one through a third
  process, or turning it into a call, silently reorders them.
- **A configuration refresh reaching in-flight work.** A new policy applies
  to the next unit of work; the one in flight keeps the values it started
  under. Reading `state.policy` when a timer is armed, instead of a copy
  captured at open, is the bug, and a test that fires the timer by hand
  cannot see it.
- **A held struct that flows onward.** A worker that keeps the arguments it
  was started with and passes them into every process it starts must be
  refreshed on every change class that can reach it, not only the class
  someone labelled "refresh". Follow where the held value goes.
- **Child order that makes the stop lie.** Reverse-order shutdown decides
  which teardown message arrives first. If a producer stops before the
  consumer that must close cleanly, the consumer sees the producer's stop
  as a failure and records it as one. The side that must close first goes
  last in the child list.
- **A read-path lookup treated as liveness.** `Registry.whereis` and
  similar reads can return a dead pid until the registry processes its
  DOWN. A gate on a name must also check `Process.alive?/1`. The register
  path is different: a unique `Registry.register` evicts a dead holder and
  retries, so terminate-then-start of a named child needs no wait between.
- **`terminate/2` doing less than the process's normal close.** A process
  that traps exits so it can clean up on a supervisor's `:shutdown` should
  run the same close it would run in the ordinary case — same order, same
  notifications — and return without awaiting other processes, because a
  supervisor's shutdown budget is not a place to wait out another process's
  work or a timer window. A crash reason should do nothing; restore covers it.
- **A comment that declares a case impossible.** Comments asserting a
  guarantee ("can never", "the only caller", "already announced before")
  are the ones most often false after a refactor, and most often hiding a
  defect. Check the claim against the code, not the diff.
- **A test that passes in both states.** A test added to pin a fix must
  fail without it. Prefer real processes and real timers over stubs and
  manual timer firing when ordering or duration is the thing under test.
  Synchronize with monitors, `assert_receive`, and `:sys.get_state/1`
  barriers, never `Process.sleep` polling. A test that starts a real
  process writing to a database or a directory must give it sandbox access
  and await its exit before cleanup.

## Do not suggest these

Each has been proposed in review of OTP code and was wrong.

- **A reaper, reconciler, or stop-time sweep** that reaches across trees to
  end workers or drain their rows. That is imperative teardown. A stop is a
  supervisor stopping a subtree; each worker closes its own resources in
  `terminate/2`; a crash restores from a checkpoint. A worker crashing at
  the instant its subtree is stopped is a double fault whose bounded residue
  is documented, not a reason for an orchestrator.
- **An explicit "stop signal"** so a worker can tell an intentional stop
  from a supervisor restart. A supervisor's `:shutdown` is the stop signal.
  Closing cleanly on it leaves finished records instead of stranded active
  ones, and an ancestor giving up after its restart intensity is spent is a
  crash loop past its budget, where a clean close beats a stuck one.
- **Acknowledged or atomic handoffs** — a call in place of a cast — to
  close a window that message ordering does not close anyway. Ask whether
  the outcome inside the window is already honest before adding a
  rendezvous.
- **Waits on registry unregistration before a start**, or the claim that
  `Supervisor.terminate_child/2` on an already-down child fails. It returns
  `:ok` for a running, down, or restarting child and `{:error, :not_found}`
  only when no spec exists, so terminate, delete, start cannot hit
  `:already_present`.
- **A timeout on `GenServer.start_link` from init**, or a guard on
  `Process.exit` of a possibly-dead pid. A start's `:timeout` option
  defaults to `:infinity` — the 5 000 ms that comes to mind is
  `GenServer.call/3`'s default, a different function — and exiting a dead
  pid returns `true`. Both were asserted otherwise and shown false by
  running them.
- **Clustering, distribution, or multi-node consistency concerns** in a
  project whose deployment is one node. Generator boilerplate such as
  `DNSCluster` is not evidence of a cluster.
- **Resilience against the restart of a shared service** (monitor the
  PubSub, resubscribe, reconcile) when that service sits above its
  subscribers in the application tree. Its restart takes them with it, or
  the project has decided not to harden for it; either way, per-subscriber
  hardening is the over-engineering the tree exists to avoid.

## How to write a finding

Name the layer the code violates — boundary, lifecycle, ownership,
ordering — and give the concrete sequence: which process sends what to
whom, in what order, and what the user of the system then sees. A finding
that cannot be stated as a sequence is a preference, and preferences are not
raised. When the correct fix is structural — a child order, a strategy, an
owner — say that rather than proposing a guard that papers over it. When a
claim depends on OTP semantics, state the semantic explicitly and expect it
to be checked against the runtime, because confident claims about OTP
defaults are wrong often enough that a reproduction settles them.
