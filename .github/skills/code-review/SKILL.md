---
name: code-review
description: Reviews Elixir and Erlang changes against the principles of Designing Elixir Systems with OTP — process boundaries, single ownership of state, supervision trees that express restart characteristics, and let-it-crash recovery. Use when reviewing any pull request in an Elixir, Erlang, Phoenix, or OTP project, especially changes to GenServers, Supervisors, Registry, ETS, PubSub, Tasks, or process lifecycle.
---

# Reviewing OTP code

The bar is *Designing Elixir Systems with OTP*: data, functions, tests,
boundaries, lifecycles, workers. Raise a finding when code is in the wrong
layer — state without one owner, a lifecycle managed from outside the tree,
a boundary crossed by a call that should be a message — not when it could be
more defensive. Judge concerns against the project's stated deployment
shape: a race that needs a second node, tenant, or operator does not occur
in a system that has none, and coordination added to prevent it is a
regression.

**The tree owns process lifetime.** Restart behaviour is where a process
sits and its parent's strategy, never another process deciding for it.
Strategy follows dependency: `:rest_for_one` where a child needs the one
before it, `:one_for_one` where children are independent. Child order is
chosen for start and, in reverse, for stop. A design that needs a retry, a
stash, a reconcile-on-restart, or a process reaching across trees has the
ownership or the tree wrong; fix that, not the symptom.

## Flag these classes

- **A call from `init/1` back to the process starting the tree.** A child
  started from inside a server's `handle_call` that calls that server
  deadlocks until timeout. Config reaches a child through start arguments
  or a `:persistent_term`/ETS snapshot — and the same for anything the child
  starts from its own init.
- **A worker that dies with a table or process it does not own.** Callers
  outliving an ETS owner with no heir raise on the missing table; callers of
  a restarting named process exit. On a restore path that is a child failing
  to start and escalating. The owner's API reads a missing table as empty and
  drops a write to an absent owner.
- **A subscription assumed to survive its holder's replacement.** Subscriber
  lists live in the holder's state. The dependency must be a monitor, and the
  detector reports to whoever owns the outcome rather than acting on a stale
  snapshot.
- **The wrong process closing a resource.** The owner holds the current
  data; a helper holds the opening snapshot. Only an orphan (owner dead)
  closes itself, and then it emits what the owner would have.
- **Ordering relied on across a pair the messages do not share.** The BEAM
  orders messages per sender–receiver pair, whatever their kind: `cast A;
  call B; cast C` from one process to one server arrive in that order, and
  B's reply is a barrier. What breaks the order is changing the pair —
  routing one message through a third process, or sending it from a
  different process than the rest.
- **Configuration reaching work it should not.** A refresh applies to the
  next unit of work; in-flight work keeps the values it started under, so
  timers arm from a copy captured at open, not from `state.policy`. And a
  held struct that flows into processes the worker starts must be refreshed
  on every change class that can reach it.
- **Child order that makes the stop lie.** If a producer stops before the
  consumer that must close cleanly, the consumer records the producer's stop
  as a failure. What must close first goes last in the child list.
- **A read-path lookup treated as liveness.** `Registry.lookup/2` can
  return a dead pid until the registry processes its DOWN; a gate on a name
  also checks `Process.alive?/1`. Registering is different: a unique
  `Registry.register/3` evicts a dead holder and retries, so
  terminate-then-start needs no wait.
- **`terminate/2` doing less than the normal close.** Trap exits, run the
  ordinary close in the ordinary order on `:shutdown`, and return without
  awaiting other processes. A crash reason does nothing; restore covers it.
- **A comment declaring a case impossible.** "Can never", "the only
  caller", "already announced" are the claims most often false after a
  refactor and most often hiding a defect. Check them against the code.
- **A test that passes in both states.** A test pinning a fix must fail
  without it. Prefer real processes and timers to stubs and manual firing
  when ordering or duration is under test; synchronize with monitors,
  `assert_receive`, and `:sys.get_state/1`, never `Process.sleep` polling.

## Do not suggest these

- **A reaper, reconciler, or stop-time sweep** across trees. A stop is a
  supervisor stopping a subtree; each worker closes its own resources in
  `terminate/2`; a crash restores from a checkpoint. A worker crashing at
  the instant its subtree stops is a double fault to document, not an
  orchestrator to build.
- **An explicit stop signal** to distinguish an intentional stop from a
  crash. The exit reason already says which: a process that must react to
  another's end links or monitors it and reads `:shutdown`, `{:shutdown, _}`
  or `:normal` against a crash reason from the `EXIT` or `DOWN` message, and
  the stopping process receives the same reason in `terminate/2`. Neither
  side needs a bespoke message. Closing cleanly on `:shutdown` beats
  stranded state, and an ancestor past its restart budget is a crash loop
  where a clean close beats a stuck one.
- **A call in place of a cast** to close a window that ordering does not
  close anyway. Ask whether the outcome inside the window is already honest.
- **Waits on registry unregistration before a start**, or the claim that
  `Supervisor.terminate_child/2` on a down child fails: it returns `:ok` for
  a running, down, or restarting child, `{:error, :not_found}` only with no
  spec, so terminate, delete, start cannot hit `:already_present`.
- **A timeout on `GenServer.start_link`** or a guard on `Process.exit` of a
  dead pid. A start's `:timeout` defaults to `:infinity` (5 000 ms is
  `GenServer.call/3`'s default); exiting a dead pid returns `true`.
- **Cluster or multi-node concerns** in a single-node project. Generator
  boilerplate such as `DNSCluster` is not evidence of a cluster.
- **Per-subscriber hardening against a shared service's restart** (monitor
  the PubSub, resubscribe, reconcile) when that service sits above its
  subscribers in the tree.

## Writing a finding

Name the layer violated — boundary, lifecycle, ownership, ordering — and
give the sequence: which process sends what to whom, in what order, and
what the user then sees. A finding that cannot be stated as a sequence is
a preference; do not raise it. When the fix is structural — a child order,
a strategy, an owner — say so instead of proposing a guard. State any OTP
semantic a claim rests on; confident claims about OTP defaults are wrong
often enough that a reproduction settles them.
