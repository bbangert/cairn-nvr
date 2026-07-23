---
title: App-boot DB writes commit outside the Ecto sandbox and pollute the suite
tags: [ecto, sandbox, testing, phoenix, flaky-tests]
date: 2026-07-22
module: Cairn.Boot / Cairn.Reconciler
---

# Problem

Four unrelated tests started failing with "extra" event rows. Cause chain:

1. The app runs a boot task (disk↔index reconciliation) that INSERTs rows.
2. In `mix test`, the application starts **before** `test_helper.exs` sets
   `Sandbox.mode(:manual)` — boot-time queries run in the sandbox's
   default automatic mode and are **committed for real** to the test db.
3. The test `data_dir` is shared across runs; an earlier integration test
   left clip files on disk → every subsequent boot "adopted" them as new
   rows → every list/count assertion in the suite drifted.

The insidious part: the pollution came from a *previous* run's leftover
files, so failures appeared far from their cause and only on the second
run.

# Solution

Clean shared state in `test_helper.exs` (runs after app boot, still in
automatic mode, so the cleanup also commits):

```elixir
File.rm_rf!("tmp/cairn_test_data/events")
File.rm_rf!("tmp/cairn_test_data/snapshots")
Cairn.DataDir.ensure!("tmp/cairn_test_data")
Cairn.Repo.delete_all(Cairn.Events.Event)
ExUnit.start(exclude: [:integration])
Ecto.Adapters.SQL.Sandbox.mode(Cairn.Repo, :manual)
```

# Rule of thumb

Any app that writes to the DB at boot (migrator aside) will do committed
writes in the test env. Either gate the boot work behind an env flag, or
reset its effects in `test_helper` before `ExUnit.start`.
