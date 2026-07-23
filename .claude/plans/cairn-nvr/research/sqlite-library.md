# Library Research: SQLite access layer (ecto_sqlite3 vs raw exqlite)

## Recommended

Both options are viable; no single winner is declared (see Thesis/Antithesis below). Both share the same
underlying NIF driver (`exqlite`), so the real decision is "Ecto on top or not," not "which SQLite driver."

### ecto_sqlite3
- **Hex**: https://hex.pm/packages/ecto_sqlite3
- **Docs**: https://hexdocs.pm/ecto_sqlite3 (redirects to https://ecto-sqlite3.hexdocs.pm/)
- **Downloads**: ~2.03M all-time, ~17.7k/week (2026-07-22 snapshot)
- **Last release**: 0.24.1, 2026-06-14 (prior: 0.24.0 on 2026-05-21, 0.23.0 on 2026-05-05) — actively maintained, monthly-ish cadence
- **Why**: Gives Ecto.Repo, Ecto.Query, Ecto.Migration, Ecto.Changeset for free. For an event index with filters (camera_id, label, time range) and pagination in a LiveView browser, composable `Ecto.Query` (`where`, `order_by`, `limit`/`offset` or keyset pagination) is much less code than hand-rolled SQL string building.
- **Usage example**:
  ```elixir
  # config/runtime.exs
  config :cairn_nvr, CairnNvr.Repo,
    adapter: Ecto.Adapters.SQLite3,
    database: Path.join(data_dir, "cairn.db"),
    journal_mode: :wal,        # default already :wal
    busy_timeout: 5_000,       # default 2_000; bump for reconciliation scan contention
    pool_size: 5

  from(e in Event,
    where: e.camera_id == ^camera_id,
    where: e.inserted_at >= ^from_ts and e.inserted_at <= ^to_ts,
    where: ^label in e.labels,
    order_by: [desc: e.inserted_at],
    limit: ^page_size
  ) |> Repo.all()
  ```

### exqlite (raw)
- **Hex**: https://hex.pm/packages/exqlite
- **Docs**: https://hexdocs.pm/exqlite
- **Downloads**: ~2.69M all-time, ~25.5k/week (2026-07-22 snapshot) — higher than ecto_sqlite3 because ecto_sqlite3 depends on it, plus other direct consumers
- **Last release**: 0.39.0, 2026-07-16 (prior: 0.38.0 on 2026-06-29, 0.37.0 on 2026-06-03) — very active, near-weekly releases
- **Why**: If Cairn's data model truly stays this small (one `events` table, a handful of columns, no joins), a thin wrapper around `Exqlite.Sqlite3` connection + prepared statements avoids pulling in Ecto's query-compilation, changeset, and migration machinery for a workload that doesn't need it.
- **Usage example**:
  ```elixir
  {:ok, conn} = Exqlite.Sqlite3.open(db_path)
  :ok = Exqlite.Sqlite3.execute(conn, "PRAGMA journal_mode=WAL")
  :ok = Exqlite.Sqlite3.execute(conn, "PRAGMA busy_timeout=5000")
  {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "INSERT INTO events (...) VALUES (...)")
  :ok = Exqlite.Sqlite3.bind(stmt, [...])
  :done = Exqlite.Sqlite3.step(conn, stmt)
  ```

## Considered but Rejected

### sqlitex
- **Why not**: Last release 1.7.1 on 2020-03-02 — over 6 years stale as of mid-2026, wraps the older `esqlite` (Erlang NIF, not the actively developed `exqlite`/sqlite3 Rust-ish driver family). Fails the "actively maintained" bar outright. Not viable for a greenfield 2026 project.

### duckdbex
- **Why not**: DuckDB is an OLAP/analytics engine, not an embedded OLTP row store. Wrong tool for a small transactional event index with frequent single-row inserts/updates from concurrent GenServers; no reason to introduce a second storage engine's semantics (and a heavier native dependency) for thousands of rows.

## No Library Needed

- Ad-hoc SQL string concatenation for the browser filters — Ecto's query DSL (if adopting ecto_sqlite3) or simple parameterized SQL with `?` placeholders (if using raw exqlite) both handle this without any extra library; no query-builder gem is warranted at this scale.
- Schema versioning: `Ecto.Migration` is not "extra" if already using Ecto — it's the point of using Ecto. If going raw exqlite, a hand-rolled `PRAGMA user_version` check + a small ordered list of SQL migration scripts run at boot is ~30 lines and sufficient; no need for a separate migration library.

## Compatibility Notes

- Elixir version requirement: exqlite 0.39 / ecto_sqlite3 0.24 both target current OTP 26/27 NIF versions (precompiled artifacts built for NIF 2.16 and 2.17); require Elixir ~> 1.14 per hex.pm metadata generation norms — verify exact floor against the version pinned by the Phoenix generator once mix.exs exists.
- Phoenix/LiveView version requirement: none directly — Ecto (already a Phoenix dependency) is the only bridge; ecto_sqlite3 just swaps the adapter, LiveView is unaffected either way.
- Known conflicts: ecto_sqlite3 explicitly does **not** support `Ecto.Adapters.SQL.Sandbox` async tests (SQLite's single-writer-transaction model conflicts with Sandbox's nested-transaction concurrency trick) — tests touching the DB must run synchronously (`async: false`) regardless of which option is chosen, since this is a SQLite constraint, not an ecto_sqlite3-specific one.

## Maturity / Maintenance (both, mid-2026 snapshot)

Both packages are published under the `elixir-sqlite` GitHub org by the same maintainer group (mrallen1/warmwaffles et al.), so their release cadences move roughly in lockstep — ecto_sqlite3 depends on exqlite and typically follows within days of an exqlite bump. Both are well past the "abandoned" risk zone: exqlite released 0.39.0 five days before this research (2026-07-16) and ecto_sqlite3 released 0.24.1 five weeks before (2026-06-14). Both comfortably clear the >50k-download and <6-month-release bars.

## aarch64 build story

exqlite ships **precompiled NIFs** (via `rustler_precompiled`-style artifact fetch at compile time) for `aarch64-linux-gnu` and `aarch64-linux-musl` (and darwin, android, armv7, riscv64, s390x, ppc64le, x86_64 variants), built against both NIF 2.16 and 2.17, confirmed on the exqlite 0.39.0 GitHub release assets. This means an ARM single-board host (e.g., Raspberry Pi CM4/5, other aarch64 SBC) building an OTP release should not need a Rust/C toolchain on-device or in the build container — `force_build: true` is only needed if precompiled artifacts are unavailable or reproducibility from source is required. Since ecto_sqlite3 depends on exqlite for the actual NIF, it inherits the same precompiled-binary story; there is no separate NIF to worry about at the Ecto layer.

## WAL mode / busy_timeout / concurrent writes

- ecto_sqlite3 defaults `journal_mode: :wal` and `busy_timeout: 2000` ms out of the box, explicitly calling WAL "vastly superior for concurrent access" in its docs. Given Cairn's write pattern (multiple short-lived EventExtractor GenServers each doing one insert + one update, plus a startup reconciliation scan potentially doing many writes), bumping `busy_timeout` to 5000+ ms is worth doing regardless of which option is chosen, since SQLite still serializes writers even in WAL mode — WAL only helps readers-vs-writer concurrency, not writer-vs-writer.
- exqlite's own docs are blunt: "Simultaneous writing is not supported by SQLite3 and will not be supported here" — i.e., the library will not queue/retry writes for you; `SQLITE_BUSY` becomes an application-level concern either way. With raw exqlite, the app must implement its own busy-timeout/retry policy (or rely on the PRAGMA) and safe connection-sharing across processes (a single named GenServer/connection-pool serializing writes is the common pattern for both approaches at this data scale — ecto_sqlite3's Ecto.Repo pool with pool_size low, or Ecto's `pool_size: 1` recommendation some SQLite/Ecto guides give, actually helps avoid busy retries better than a size-5 pool for a single small file).
- Practical implication for Cairn: with only "thousands of rows" and a handful of concurrent writers, either option's default WAL+busy_timeout combo is almost certainly enough; heavy tuning is unlikely to matter at this scale.

## Dependency footprint of ecto_sqlite3

`ecto_sqlite3` pulls in `ecto`, `ecto_sql`, `exqlite`, plus `db_connection`. Nothing here is a red flag for an embedded/single-host NVR — `ecto`/`ecto_sql` are already Phoenix defaults, `db_connection` is lightweight infra also used by Postgrex. No JDBC/JVM shims, no telemetry-heavy tracing libraries pulled in transitively beyond what a standard Phoenix app already carries. The only meaningful "cost" is Ecto's own compile-time query macro overhead and the general surface area of a full ORM layer for a single-table use case — not a runtime/footprint problem, more a "is this the right abstraction level" question, addressed in the thesis/antithesis below.

## Thesis / Antithesis

### ecto_sqlite3

**Thesis**: Cairn is a Phoenix app; Ecto is already a near-certain dependency for anything beyond the event index (config, users/auth if ever added, other tables as features grow). Using `Ecto.Query` for the LiveView browser's camera/label/time-range filters plus pagination is dramatically less code and less error-prone than hand-building parameterized SQL, and `Ecto.Migration` gives free-with-Ecto schema versioning, rollback support, and a familiar `mix ecto.migrate` release-script hook — valuable given the app will evolve past a single `events` table. Failure modes are well understood (DBConnection pool exhaustion/timeouts surface as normal Ecto errors), and the query layer scales fine to 10x/100x row counts (still thousands-to-tens-of-thousands of rows) without any adapter-level rework.

**Antithesis**: For a single table with ~6 fields and no joins, Ecto is arguably solving a problem Cairn doesn't have — schema/changeset/migration machinery, query-plan compilation, and a connection-pool abstraction are overhead for what is fundamentally "insert one row, update one row, and run a handful of SELECT ... WHERE queries." The `pool_size: 5` default is actively wrong for a single SQLite file under a single-writer constraint (concurrent writers still serialize regardless of pool size, and a larger pool increases `SQLITE_BUSY` contention/retry storms under load rather than reducing it) — Ecto's Postgres-shaped pooling model doesn't map cleanly onto SQLite's single-writer reality, and misconfiguring it is an easy footgun for a team unfamiliar with SQLite+Ecto's quirks (documented lack of Sandbox async test support is one symptom of this mismatch).

### raw exqlite

**Thesis**: The write pattern is trivially simple (one insert, one update, occasional batch reconciliation) and the read pattern is a handful of known filter shapes — this is comfortably within what 50-100 lines of hand-written parameterized SQL plus a tiny `PRAGMA user_version`-based migration runner can handle, with zero Ecto compile-time cost, zero changeset ceremony for internal-only data, and full transparency into exactly what SQL executes and when — useful for tuning WAL checkpoint behavior or diagnosing `SQLITE_BUSY` on constrained eMMC I/O without an ORM layer obscuring the query. Dependency footprint is minimal: just exqlite (and its precompiled NIF), no `ecto`/`ecto_sql`/`db_connection` chain.

**Antithesis**: Hand-rolling connection lifecycle management (a GenServer or pool wrapping the raw `Exqlite.Sqlite3` connection to serialize writers safely across concurrent EventExtractor processes), a migration runner, and dynamic filter-composition SQL (camera_id optional, label optional, time range optional, pagination) reinvents — with less testing and community scrutiny — exactly what `ecto_sqlite3` already provides and has hardened over hundreds of thousands of downloads/week. As the LiveView browser's filter combinations grow (multi-select labels, state filters, sort options), string-concatenated/conditionally-built SQL becomes harder to keep safe and readable than an equivalent `Ecto.Query` pipeline built with `Enum.reduce` over a base query. The "no Ecto needed" argument weakens the moment Cairn adds any second table (users, camera config, retention policy) — a common trajectory for NVR-class apps — at which point the team ends up building an ad hoc mini-Ecto anyway.

## Sources

- https://hex.pm/packages/ecto_sqlite3 and Hex API (`hex.pm/api/packages/ecto_sqlite3`) — download counts, release dates, checked 2026-07-22
- https://hex.pm/packages/exqlite and Hex API (`hex.pm/api/packages/exqlite`) — download counts, release dates, checked 2026-07-22
- https://hex.pm/packages/sqlitex and Hex API (`hex.pm/api/packages/sqlitex`) — confirms last release 2020-03-02
- https://github.com/elixir-sqlite/exqlite/releases (v0.39.0 assets) — precompiled NIF target list including `aarch64-linux-gnu`/`aarch64-linux-musl`
- https://ecto-sqlite3.hexdocs.pm/Ecto.Adapters.SQLite3.html — default `journal_mode: :wal`, `busy_timeout: 2000`, `pool_size: 5`, Sandbox/async-test limitation, constraint-name limitation, transaction-mode guidance
- https://github.com/elixir-sqlite/exqlite README — "Simultaneous writing is not supported by SQLite3 and will not be supported here"
