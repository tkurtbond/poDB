# poDB

poDB is a database-independent SQL interface for Oberon-2. It is written for
and compiled with **poc**, the Peaseblossom Oberon Compiler. Application code
is written once against module `Db`. It starts out on SQLite and moves to
PostgreSQL by changing the connection URL and the driver import.

`PLAN.md` is the implementation roadmap. This file holds the project's
standing decisions and conventions. When a decision changes, update this file
in the same commit.

## The design

`doc/oberon-db-interface.md` is the design. `doc/Db.Mod` and `doc/DbDemo.Mod`
are the code written with it, before poc was available. The design has three
layers:

1. `Db`: abstract `Driver`, `Connection` and `Statement` types (records with
   type-bound procedures), a driver registry keyed by URL scheme, placeholder
   translation (`Db.Translate`), and binding and column reading by name,
   written once on top of each driver's numbered procedures.
2. Drivers: `DbSqlite` and `DbPostgres`. Each extends the three types and
   registers itself from its module body, so importing a driver is what makes
   it available.
3. The native client libraries, `libsqlite3` and `libpq`, called through
   poc's `["C"]` external procedures.

The conventions in the design's section 2.4 bind every driver: parameters
are 1-based and columns 0-based, every operation first sets `c.err :=
noError`, `Step` returns FALSE both when the statement is done and when it
fails, and so on. Do not change the public interface of `Db` without asking
the user. Record any interface change in the design document too.

## Decisions

The user decided these on 2026-10-27. `PLAN.md`, "Decisions", gives the
reasons.

- **D1:** 64-bit integer values are `HUGEINT` in the public interface.
- **D2:** SQLite URLs are `sqlite:<path>`. `sqlite:demo.db` is relative,
  `sqlite:///abs/file.db` is `/abs/file.db`, and `sqlite::memory:` or
  `sqlite:///:memory:` is an in-memory database.
- **D3:** there are three poc libraries: `db` (`Db`, `DbCStrings`),
  `db-sqlite` (`-link -lsqlite3`) and `db-postgres` (`-link -lpq`).
- **D4:** parameters are numbered from 1 and columns from 0, as in the
  design.
- **D5:** each PostgreSQL prepared statement gets a unique name per
  connection, and `Finalize` runs `DEALLOCATE` on it.
- **D6:** PostgreSQL parameters and results use text format. The driver
  formats numbers as text to bind them and parses text to read them.
- **D7:** `doc/Db.Mod` and `doc/DbDemo.Mod` stay unchanged as part of the
  design. The working copies are `src/Db.Mod` and `examples/DbDemo.Mod`.

## The compiler: the installed poc, not a source build

- Use the **Fedora package** `peaseblossom` (0.9.0 when this was written):
  `/usr/bin/poc`, with its runtime library `poc-rtl` under
  `/usr/lib/poc/<triple>/{O2,O2-g,OC,OC-g}`. `poc -version` shows the
  version, the target and the clang it drives (clang 22 on atla). Do not
  build poc from `~/Repos/Oberon/Peaseblossom`, and do not put its
  `build/bin` on `PATH`.
- `~/Repos/Oberon/Peaseblossom` is **read-only reference material** for this
  project. The useful parts:
  - `doc/users-guide.md`: section 3 (building), 4 (the import path), 5
    (libraries), 9 (calling C) and 10 (the runtime modules).
  - `doc/reference-guide.md`: the full account of what poc accepts.
  - `AGENTS.md`, "Language extensions beyond Oberon2.pdf".
  - `rtl/llvm/*.Mod`: the runtime modules' interfaces (`Out`, `Err`,
    `Strings`, `Args`, `GarbageCollectedHeap`).
- If poc seems to be wrong, write a minimal reproducer in the scratch
  directory and tell the user before working around it. If you do use a
  workaround, mark it with a comment that names the bug.

### What poc does that matters here

- **Size models.** Under `-O2` (the default) `INTEGER` is 16 bits and
  `LONGINT` 32. Under `-OC` they are 32 and 64. `HUGEINT` is 64 bits under
  both. A program and every module and library it uses share one size model.
  poDB must build and pass its tests under **both** models.
- **C types.** A C `int` is `SYSTEM.INT32`. A `sqlite3_int64` or `int64_t` is
  `SYSTEM.INT64`. A `double` is `LONGREAL`. Any pointer or `size_t` is
  `SYSTEM.ADDRESS`. This mapping is the same under both size models. Never
  declare a C parameter as `INTEGER` or `LONGINT`.
- **External procedures.** `PROCEDURE ["C", "sqlite3_open_v2"] Open(...):
  SYSTEM.INT32;` declares one with no body. Keep the Oberon names
  descriptive and give the C name as the second string. Declare externals
  only in the driver module that uses them, and do not export them.
- **Strings to C.** Oberon strings are 0X-terminated arrays. Pass
  `SYSTEM.ADR(s)` of a 0X-terminated `ARRAY OF CHAR`. A value open-array
  parameter is a copy that lives only for the duration of the call, so C must
  copy anything it keeps. SQLite does, given `SQLITE_TRANSIENT`.
- **Strings from C.** A `const char *` is a `SYSTEM.ADDRESS`. Copy it into the
  caller's buffer, truncating to fit and always ending with 0X. One shared
  helper does this, so the drivers do not each write their own.
- **C parts.** A file `<Module>.c` beside `<Module>.Mod` is compiled and
  linked with the module. Use one only for what Oberon cannot do safely,
  above all calls to **variadic** C functions such as `snprintf`. Never
  declare a variadic function as `["C"]`.
- **Native libraries.** `-link -lsqlite3` and `-link -lpq`. A poc library
  built with `-link` records those arguments, and every program that uses the
  library is linked with them.
- **Traps.** poc checks NIL dereferences, indexes, type guards and a function
  that reaches its `END`, and exits with a status of its own (User's Guide,
  section 7). `-trap-location` adds the file and line. Use it while debugging.
- **Declare before use** applies to type-bound procedures too. Use a forward
  declaration (`PROCEDURE ^ (s: Statement) Step* (): BOOLEAN;`) when one is
  called before it is declared.

## Language rules for poDB's source

- Write Oberon-2 as `Oberon2.pdf` defines it, as checked by `poc -strict`.
  The **one adopted extension is `HUGEINT`**, for 64-bit integer values in
  the public interface (`PLAN.md`, decision D1). Any other extension needs
  the user's approval first.
- Index character arrays with `LONGINT`, not `INTEGER`. Under `-O2` an
  `INTEGER` stops at 32767, and SQL text or a column value can be longer.
- Match the style of `doc/Db.Mod`: two-space indentation, a comment under
  each exported procedure's heading saying what it does, descriptive names,
  and section comments of the form `(* ---- Name ---- *)`.
- Every module begins with a comment saying what it is for.

## Layout

| Path | What it holds |
|---|---|
| `doc/` | The design: `oberon-db-interface.md`, with the original `Db.Mod` and `DbDemo.Mod` as part of it. **Never edit or build those two files.** |
| `src/` | The library modules that are built and tested: `Db.Mod` (started as a copy of `doc/Db.Mod`), `DbCStrings.Mod`, `DbSqlite.Mod`, `DbPostgres.Mod` (+ `DbPostgres.c`) |
| `examples/` | `DbDemo.Mod` (started as a copy of `doc/DbDemo.Mod`) and other example programs |
| `test/` | Test programs, the outputs they are expected to print, and the PostgreSQL test cluster scripts |
| `build/` | Everything the build writes (ignored by git) |
| `GNUmakefile` | The build and the checks |

## Building and checking

- `make`: build the poDB libraries under both size models in `build/`.
- `make check`: run every test that needs no server (the `Db` unit tests and
  the SQLite driver) under `-O2` and `-OC`, plus `poc -strict -check` of
  every module that does not use `HUGEINT`.
- `make check-postgres`: start the test cluster (if it is not running), run
  the PostgreSQL and cross-driver tests, then stop it.
- `make check-all`: `check` plus `check-postgres`.
- Run `make check-all` before every commit. If PostgreSQL cannot run, say so
  in the commit message.
- Temporary files go in the session's scratch directory, never in the
  repository. Build output goes in `build/`.

## PostgreSQL for testing

- The tests use a **throwaway local cluster** owned by the user, made with
  `initdb` under `build/pgdata`. It listens only on a Unix socket in
  `build/pgsock` (no TCP), with `trust` authentication. It is never the
  system's PostgreSQL service, and nothing here needs root.
- It uses the packages `postgresql-server` (for `initdb`, `pg_ctl`) and
  `libpq-devel` (for the `libpq.so` link name). Both are installed on atla.
  Installing packages is the user's job. Ask; do not run `dnf` yourself.
- A Unix socket's path is limited to 107 bytes. The socket cannot go under
  the session's scratch directory, whose path is too long. `build/pgsock` in
  this checkout is fine.
- Never write a real password, host or user name into the repository, a test
  or a commit. The test URL comes from `PODB_PG_URL`, which defaults to the
  local socket.

## Git

- Work on `main` unless the user asks for a branch. Commit only when the user
  asks.
- Commit messages: a short summary line, a blank line, then what changed and
  why.
