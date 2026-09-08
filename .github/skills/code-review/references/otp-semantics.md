# OTP runtime semantics a review may rest on

Each entry is a fact about the runtime, not a policy. Confident claims
about these are wrong often enough that a reproduction settles them; when a
finding depends on one, state it and expect it to be checked.

## Message ordering

The BEAM keeps message order per sender–receiver pair, whatever the message
kind. `cast A; call B; cast C` from one process to one server arrive in that
order, and B's reply is a barrier the caller can rely on. Order is lost only
when the pair changes: a message routed through a third process, or sent
from a different process than the rest. A finalize that must follow the data
it closes therefore leaves the same process the data left, for the same
receiver.

## Registry

`Registry.lookup/2` reads a table the registry maintains asynchronously: a
dead pid stays visible until the registry processes its `DOWN`, so a lookup
is not a liveness check and a gate on a name also checks
`Process.alive?/1`. Registering is different: a unique `Registry.register/3`
that collides with a dead holder evicts it and retries, so only a live
holder yields `{:error, {:already_registered, pid}}`. Terminate-then-start
of a named child needs no wait on unregistration between the two.

## Supervisor child management

`Supervisor.terminate_child/2` returns `:ok` for a running, already-down, or
restarting child — the spec stays — and `{:error, :not_found}` only when no
spec exists. Terminate, delete, start from one caller against a supervisor
that is not itself restarting cannot hit `{:error, :already_present}`. The
three calls are serialized, not atomic: a second caller managing the same
child id, or a supervisor rebuilding its static specs in between, can.
`Supervisor.start_child/2` appends, so a replaced child sits last in the
child list and stops first on the next reverse-order shutdown; no call
reorders a spec in place.

## Lifecycle coupling by strategy

`:rest_for_one` restarts a child and every child ordered after it. A
subscriber ordered after its holder restarts with the holder; one ordered
before it, or a `:one_for_one` sibling, or a process in another tree,
survives the holder's replacement holding a subscription the new holder
never heard of. "Above" in the tree does not by itself mean "restarts with":
`:one_for_one` children under a shared service are independent of it.

## Start and stop

`GenServer.start_link/3`'s `:timeout` option defaults to `:infinity`; the
5 000 ms that comes to mind is `GenServer.call/3`'s default, a different
function. `Process.exit/2` on a dead pid returns `true`. `terminate/2` runs
only when the process traps exits or the exit comes from inside it, and not
at all on `:kill` — including a supervisor's forced kill after its shutdown
timeout — so cleanup only `terminate/2` performs is a leak waiting for a
kill. A linked port or socket dies with its owner regardless.

## Exit reasons

A linked or monitoring process reads why another ended from the `EXIT` or
`DOWN` message: `:normal`, `:shutdown`, `{:shutdown, term}`, or a crash
reason. The stopping process receives the same reason in `terminate/2`.
Nothing further is needed to tell an intentional stop from a failure.
