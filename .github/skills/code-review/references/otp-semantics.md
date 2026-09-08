# OTP runtime semantics a review may rest on

Each entry is a fact about the runtime with its edges, not a policy.
Confident claims about these are wrong often enough that a reproduction
settles them; when a finding depends on one, state it and expect it to be
checked. Sources: hexdocs `Supervisor`, `DynamicSupervisor`, `GenServer`,
`Task`, `Registry`, `PartitionSupervisor`; Erlang `supervisor`, `ets`,
`persistent_term`; Hébert, *Erlang in Anger* and "Handling Overload".

## Restart types

`:permanent` restarts on any exit. `:transient` restarts only on a reason
other than `:normal`, `:shutdown`, or `{:shutdown, term}` — a worker that
must come back after its own `{:stop, :normal, state}` needs `:permanent`.
`:temporary` never restarts and is deleted from the child list on exit, so
a `:temporary` child placed to run "again" runs once; right for a one-shot
whose failure is not the tree's business. A `:transient` or `:temporary`
child may be `significant: true`, and `auto_shutdown: :any_significant |
:all_significant` makes the parent stop itself when it exits — the tree
saying "this subtree exists for that child" instead of a reaper. The
default `:never` is right whenever the parent has its own reasons to live.

## Shutdown budget

The supervisor sends `:shutdown`, waits the child's `shutdown` value, then
kills. Default 5 000 ms for a worker, `:infinity` for a supervisor — and a
supervisor child must keep `:infinity`, anything else races its own
children's teardown. `:infinity` on a worker makes the whole tree's
teardown wait on that worker returning; `:brutal_kill` skips `terminate/2`
and is right for a process holding nothing that can be flushed.

## Restart intensity

`max_restarts: 3` in `max_seconds: 5` by default. Exceeding it terminates
every child and the supervisor with `:shutdown`, escalating upward; under a
DynamicSupervisor one crash-looping `:permanent` child takes every sibling.
Reconnect backoff belongs inside the worker, never in supervisor restarts.
`DynamicSupervisor` `:max_children` defaults to `:infinity`; the exceeded
case is `{:error, :max_children}`, a clean signal to shed on. Unbounded is
right when the count is bounded upstream, and then the bound belongs in a
comment.

## Start, continue, stop

`GenServer.start_link/3`'s `:timeout` defaults to `:infinity`; the 5 000 ms
that comes to mind is `GenServer.call/3`'s. Work in `init/1` blocks the
starter, and under a supervisor the whole start sequence — right only when
a later child must not start until this one is ready. `{:continue, arg}`
from `init/1` runs before any other message; `send(self(), :init)` does
not, because a registered name already attracts messages.
`terminate/2` runs when a callback returns `:stop`, raises, or returns a bad
value, and on an external exit signal only when the process traps exits;
never on `:kill`, including a supervisor's forced kill after the shutdown
budget. So cleanup that only `terminate/2` performs is a leak waiting for a
kill. A linked port dies with its owner; the OS process behind it may not,
and a hung one needs its `os_pid` killed. `Process.exit/2` on a dead pid
returns `true`.

## Exit reasons

A linked or monitoring process reads why another ended from the `EXIT` or
`DOWN` message: `:normal`, `:shutdown`, `{:shutdown, term}`, or a crash
reason. The stopping process receives the same reason in `terminate/2`.
Nothing further is needed to tell an intentional stop from a failure.

## Calls, replies, mailboxes

`GenServer.call/3` exits the caller with `:timeout` after 5 000 ms; since
OTP 24 the call uses a process alias, so a late reply is dropped rather
than leaking into the mailbox. Raising the timeout is right for a
known-slow external, not on a supervisor-critical path. A deferred reply —
`{:noreply, state}` now, `GenServer.reply/2` later from any process — keeps
a server responsive across slow work; the `from` must be tracked, and a
crash between the two leaves the caller to its own timeout. A mailbox is
bounded only by memory: a `cast` or `send` producer faster than its
consumer kills the node by memory with no error at the producer. A `call`
is implicit back-pressure; deliberate shedding (a latest-wins slot, a drop
counter) is the alternative, and dropping silently is the bug.

## Message ordering

The BEAM keeps message order per sender–receiver pair, whatever the message
kind: `cast A; call B; cast C` from one process to one server arrive in that
order, and B's reply is a barrier. Order is lost only when the pair changes:
a message routed through a third process, or sent from a different process
than the rest.

## Tasks

`Task.async/1` links and monitors the caller and always sends its reply:
an un-awaited task leaks a message and its crash kills the caller, and only
the calling process may await. `Task.Supervisor.async_nolink/3` (the
child must be `:temporary`, the default) is the one that does not take a
GenServer down; `Task.Supervisor.start_child/3` is fire-and-forget.
`Task.async_stream/3` defaults to 5 000 ms per element with
`on_timeout: :exit` — the caller exits — and `ordered: true`, which buffers;
`async_stream_nolink` under a `Task.Supervisor` is the form safe inside a
GenServer.

## Registry

Lookup, dispatch, and register run in the calling process against the
partition's ETS; the registry process only holds the monitors, and it
processes a `DOWN` asynchronously. So `Registry.lookup/2` can return a dead
pid, and a read used to decide whether something is running needs
`Process.alive?/1` or a wait. Registering is different: a unique
`Registry.register/3` that collides with a dead holder evicts it and
retries, so only a live holder yields `{:error, {:already_registered, pid}}`
and terminate-then-start needs no wait between. `:via` requires `:unique`;
`:duplicate` keys are the pub-sub shape; `:partitions` above the default 1
helps only for measured contention.

## Supervisor child management

`Supervisor.terminate_child/2` returns `:ok` for a running, down, or
restarting child — the spec stays — and `{:error, :not_found}` only with
no spec. Terminate, delete, start from one caller against a supervisor that
is not itself restarting cannot hit `:already_present`; the calls are
serialized, not atomic, so a second caller on the same child id, or a
supervisor rebuilding its static specs between them, can.
`Supervisor.start_child/2` appends, so a replaced child sits last and stops
first on the next reverse-order shutdown; nothing reorders a spec in place.

## Lifecycle coupling by strategy

`:rest_for_one` restarts a child and every child ordered after it. A
subscriber ordered after its holder restarts with the holder; one ordered
before it, a `:one_for_one` sibling, or a process in another tree survives
the holder's replacement holding a subscription the new holder never heard
of. "Above" in the tree does not mean "restarts with". `PartitionSupervisor`
shards a measured singleton across schedulers; its routing is unstable
across versions, so nothing may persist a partition index.

## Tables and terms

An ETS table dies with its owner unless `{:heir, pid, data}` is set, in
which case the heir receives `{:"ETS-TRANSFER", tab, from, data}`;
`:ets.give_away/3` transfers ownership without changing the heir.
`read_concurrency` costs on read/write alternation and `write_concurrency`
on reads; a table with one writer wants neither. A `:persistent_term` read
is free; a `put` or `erase` scans every process heap and can pause the
node, so it fits config written on reload and read everywhere, not
anything per request.

## Timers

`Process.cancel_timer/1` does not remove a message already delivered, so a
debounce that cancels and re-arms carries a `make_ref()` token checked on
receipt; cancelling without one is fine only when the handler is idempotent
for the stale case. `:hibernate` forces a full GC and a compact heap — right
for many mostly-idle processes, a GC per message on a busy one; reach for
it only with a measured heap.
