# PLAN.md: implementing poDB with poc

## Context

`doc/oberon-db-interface.md` designs a database-independent SQL interface for
Oberon-2. `doc/Db.Mod` (the interface and the shared logic) and
`doc/DbDemo.Mod` (an example program) were written before poc was available,
and the two drivers were not written at all. This plan turns the design into
working, tested libraries built with the installed poc (the Fedora package
`peaseblossom` 0.9.0, `/usr/bin/poc`). `AGENTS.md` has the conventions the
work follows.

### State of the machine (atla, 2026-10-27)

| Item | State |
|---|---|
| poc | 0.9.0, `/usr/bin/poc`, runtime in `/usr/lib/poc`, clang 22.1.8 |
| SQLite | `sqlite-devel` 3.51.2 installed: `sqlite3.h` and `libsqlite3.so` are there |
| libpq | `libpq-devel` 18.0 installed: `libpq-fe.h` and `libpq.so` are there |
| PostgreSQL server | `postgresql-server` 18.6 installed (`initdb`, `pg_ctl`) |

A throwaway cluster made as Phase 4 describes, under the repository's
`build/`, started without root, created `podb_test`, and answered `psql` at
`postgres:///podb_test?host=<abs>/build/pgsock&user=podb`.

The server would not start with its socket under the session's scratch
directory. A Unix socket's path is limited to 107 bytes, and that path,
ending in `.s.PGSQL.5432`, was 114. Under `/home/tkb/Repos/Oberon/poDB/build/pgsock`
it is 54.

### What compiling the design with poc showed

`poc -compile doc/Db.Mod` (run in a scratch directory) fails:

    Db.Mod:248:11: error: undeclared field or type-bound procedure: Step
    Db.Mod:249:4: error: undeclared field or type-bound procedure: Finalize

`Connection.Exec` calls `Statement.Step` and `Statement.Finalize`, which are
declared after it. With two forward declarations added before the Connection
section, `Db.Mod` compiles under `-O2` and `-OC` and passes `poc -strict
-check`:

    PROCEDURE ^ (s: Statement) Step* (): BOOLEAN;
    PROCEDURE ^ (s: Statement) Finalize* ;

Reading the code turned up these further problems. Phase 1 fixes them.

1. **Integer width.** The interface uses `LONGINT` for column and parameter
   values. Under poc's default `-O2`, `LONGINT` is 32 bits, so 64-bit keys
   would be cut short. See decision D1.
2. **`INTEGER` indexes.** `Translate`, `SameName` and `Open` index character
   arrays with `INTEGER`. Under `-O2` that is 16 bits, so SQL text longer than
   32767 characters wraps the index and traps.
3. **The demo's URL.** `sqlite:///demo.db` names `/demo.db`, a file at the
   root of the file system. See decision D2.
4. **`Db.Open`'s scheme check.** If the scheme is 31 characters or longer,
   the loop stops at the buffer's end rather than at the `:`, and `Open`
   reports "no scheme" instead of "no driver".
5. **`ColumnIndex`.** It reads each column name into a 64-character buffer,
   so a column whose name is 64 characters or longer never matches.
   PostgreSQL's limit is 63 bytes, so a 128-character buffer covers it.
6. **`DbDemo`.** It needs only small changes for poc. `Out` exists and
   `Out.Int` takes a `HUGEINT`, so the `SHORT(...)` there can go.

## Decisions

The user decided all of them on 2026-10-27.
`AGENTS.md`, "Decisions", records the decided ones.

| # | Question | Decision |
|---|---|---|
| D1 | 64-bit integer values | **Decided: `HUGEINT`** in the public interface (`BindInt`, `ColumnInt`, ...). It is 64 bits under both size models, and poc's own `Out.Int` takes it. It is a poc extension, so `Db` fails `-strict`. |
| D2 | SQLite URL form | **Decided:** `sqlite:<path>`, where the path runs to the end of the URL: `sqlite:demo.db` is relative, and `sqlite:///abs/file.db` gives `/abs/file.db` (the `//` with an empty host is dropped). `sqlite::memory:` and `sqlite:///:memory:` both mean an in-memory database. |
| D3 | How the libraries are split | **Decided:** three poc libraries: **`db`** (`Db`, `DbCStrings`), **`db-sqlite`** (built with `-link -lsqlite3`) and **`db-postgres`** (built with `-link -lpq`). A program that uses only SQLite then never needs libpq. |
| D4 | Parameter and column index bases | **Decided:** keep the design's choice: parameters 1-based, columns 0-based (design section 2.7). |
| D5 | PostgreSQL prepared-statement names | **Decided:** each statement gets a unique name per connection (`podb_1`, `podb_2`, ...), and `Finalize` deallocates it (with `PQclosePrepared`; see Phase 4). A single unnamed statement would be replaced by the next `Prepare`. |
| D6 | PostgreSQL parameter and result format | **Decided: text** for both. `BindInt` and `BindReal` format the value as text, and `ColumnInt` and `ColumnReal` parse it. The server infers each parameter's type, and every column type can be read, at least as text. Binary would need exact types for every parameter and a decoder for every result type. libpq sets the format per parameter, so a later `BindBlob` can use binary for its parameters alone. |
| D7 | Where the source files live | **Decided:** `doc/Db.Mod` and `doc/DbDemo.Mod` stay in `doc/`, unchanged, as part of the design. The working versions, which are built and tested, are copies of them: `src/Db.Mod` and `examples/DbDemo.Mod`. |

## Phase 0: Scaffolding

1. `.gitignore` (`build/`, `*.sym`, `*.ll`, `*.o`, `*.c.o.d`).
2. The directories in `AGENTS.md`, "Layout". Copy `doc/Db.Mod` to
   `src/Db.Mod` and `doc/DbDemo.Mod` to `examples/DbDemo.Mod` (D7). From
   then on only the copies change. The originals in `doc/` stay as they are.
3. A `GNUmakefile` with the targets `all`, `check`, `check-postgres`,
   `check-all` and `clean`. Each size model builds in its own directory
   (`build/O2`, `build/OC`), because modules compiled under one model cannot
   be mixed with modules compiled under the other. Variables: `POC ?= poc`,
   `MODELS ?= O2 OC`.
4. A smoke test: a program calling `sqlite3_libversion()` through `["C"]`,
   built with `-link -lsqlite3`, prints `3.51.2`. This shows that externals,
   `-link` and the copying of C strings all work before any real code is
   written.

**Done when** `make check` runs the smoke test under both models.

## Phase 1: `Db`, the core, tested without a database

1. Fix `src/Db.Mod`: add the forward declarations, carry out D1 (the
   `LONGINT` values become `HUGEINT`), and fix problems 2-5 above.
2. Write `src/DbCStrings.Mod`, the shared C-string helpers:
   - `Length(p: SYSTEM.ADDRESS): SYSTEM.ADDRESS`, through `strlen` (a
     `size_t`, so `ADDRESS` rather than `LONGINT`).
   - `Copy(p: SYSTEM.ADDRESS; VAR out: ARRAY OF CHAR)`: truncates to fit,
     always ends with 0X, and treats NIL as "".
   - `Fits(p; VAR out): BOOLEAN`, so a caller can find out that a value was
     truncated.
3. Write `test/MockDriver.Mod`, a driver for the scheme `mock:` that keeps
   canned rows in memory and records every bind call it receives. It tests
   all of `Db`'s shared logic with no database present.
4. Write `test/TestDb.Mod`, which prints one line per case and is compared
   with `test/TestDb.expected`. It covers:
   - **`Translate`**: positional, named, a repeated name, `::` casts, quoted
     strings and identifiers, both comment styles, mixed `?` and `:name`
     (FALSE), 64 and 65 parameters, a 31- and a 32-character name, an output
     buffer one character too small, and SQL text longer than 32767
     characters under `-O2`.
   - **`Open`**: no scheme, an unknown scheme, a scheme that is too long, and
     two drivers registered at once.
   - **Binding by name**: an unknown name sets `errRange`, and the binds
     arrive at the mock driver under the right numbers.
   - **Columns by name**: case-insensitive matching, the first of two
     duplicate names, an unknown name, and a 63-character name.
   - **`Exec`, `Begin`, `Commit` and `Rollback`**, through the mock driver.

5. Build the `db` library (D3) under both models in `build/lib`, and build
   the tests against it rather than against `src/`.

**Done when** `TestDb` passes under both models.

**Done.** Learned on the way:
- Oberon-2 strings cannot contain their own quote character or a control
  character, and there is no string concatenation, so `TestDb` spells such
  SQL with stand-in characters (`Spell`).
- A count such as 35000 does not fit an `INTEGER` under `-O2`; test helpers
  that build long strings take `LONGINT` counts.
- `poc -library` writes the library to `<triple>/<model>/` under the current
  directory, so the makefile runs it in `build/lib`, and `-library-path
  build/lib` finds both models. A test program that imports `Db` takes it
  from the library, not from `src/`.

## Phase 2: `DbSqlite`

1. Declare the externals in `src/DbSqlite.Mod`, typed as `AGENTS.md`, "C
   types", says: `sqlite3_open_v2`, `close_v2`, `errmsg`, `prepare_v2`,
   `bind_null`, `bind_int64`, `bind_double`, `bind_text`,
   `bind_parameter_count`, `step`, `reset`, `clear_bindings`, `finalize`,
   `column_count`, `column_name`, `column_type`, `column_int64`,
   `column_double` and `column_text`. Handles (`sqlite3 *`,
   `sqlite3_stmt *`) are `SYSTEM.ADDRESS` fields of the driver's records. The
   collector does not trace them, which is right: they are not Oberon heap
   objects.
2. `Open`: parse the URL (D2), call `sqlite3_open_v2` with `READWRITE |
   CREATE`, and pass the address of the handle field with `SYSTEM.ADR`. A
   failure sets `Db.lastError` from `sqlite3_errmsg` and closes the handle,
   which SQLite allocates even when the open fails.
3. `Prepare`: run `Db.Translate(sql, "?", ...)`, then `sqlite3_prepare_v2`,
   then set `s.conn`. If `sqlite3_bind_parameter_count` disagrees with
   `params.n`, that is an `errSql` error, so a placeholder `Translate` missed
   cannot go unnoticed.
4. `Bind*`: `BindText` passes `SQLITE_TRANSIENT` (the address -1) and an
   explicit byte length (to the 0X), so SQLite copies the text before the
   Oberon copy disappears. A non-`SQLITE_OK` result maps to `errRange` or
   `errSql`.
5. `Step`: `SQLITE_ROW` (100) returns TRUE, `SQLITE_DONE` (101) returns FALSE
   with no error, and anything else returns FALSE and sets `errSql` with the
   message.
6. The column readers map `SQLITE_INTEGER`/`FLOAT`/`TEXT`/`NULL` to `Db`'s
   type codes. A `BLOB` is reported as `typeText` for now.
7. `Reset` calls `sqlite3_reset` and `sqlite3_clear_bindings`. `Finalize`
   finalizes the statement and sets its handle to NIL. A second `Finalize`
   does nothing. `Close` uses `sqlite3_close_v2`, so a connection closed
   while it still has statements is freed once they are finalized.
8. The module body registers the driver under `sqlite`.
9. `examples/DbDemo.Mod`: the D2 URL and `Out.Int` without `SHORT`. Run it
   against `sqlite::memory:` and against a file in `build/`. A second run
   against the file has to cope with rows already there, so the demo deletes
   them first (or uses `INSERT ... ON CONFLICT DO NOTHING`).

**Done when** `DbDemo` prints the expected rows under both models, built
against the `db` and `db-sqlite` libraries (D3) and also from source.

**Done.** Learned on the way:
- `sqlite3_prepare_v2`'s tail pointer gives where the first statement ends.
  The offset from the start of the buffer is an `ADDRESS`, which does not
  fit a `LONGINT` under `-O2`, so `OnlySpace` takes an `ADDRESS` index.
- A C `int` result becomes an `INTEGER` through `LONGINT`: an `INT32` is
  assignable to `LONGINT` under both models, and `SHORT(LONGINT)` is
  `INTEGER` under both (`DbSqlite.ToInteger`).
- `Translate` can lengthen SQL: `:a` may become `?10`, and each `?` up to
  `?64`. `Prepare` allocates `LEN(sql) * 3/2 + 130` characters for its
  output.
- Column readers check that a row is current and the column exists, since
  SQLite leaves both undefined.
- `DbDemo` takes an optional URL argument, defaulting to `sqlite:demo.db`.
  `make check` runs it in memory, twice against one file, and built from
  source. Its expected output is `test/DbDemo.expected`.

## Phase 3: The shared tests, run against SQLite

`test/Conformance.Mod` is one program that takes its URL from the command
line (module `Args`) and prints one line per case. It is compared with
`test/Conformance.expected`. It is written once and later run against both
drivers. It uses only the common SQL subset (design section 4). It covers:

- Creating, inserting, selecting, updating and deleting, with named and
  positional parameters, and a name used twice in one statement.
- `HUGEINT` round trips: `MAX(HUGEINT)`, `MIN(HUGEINT)` and 0.
- `LONGREAL` round trips, including values that print the same only with 17
  significant digits.
- NULL: `BindNull`, `ColumnType` = `typeNull`, and the 0 or "" that the
  readers return for it.
- Text: empty text, quotes, `--` and `:x` inside a string literal, UTF-8
  bytes, and text longer than the caller's buffer (truncated, and still
  ending with 0X).
- Transactions: commit, and rollback that leaves no rows behind.
- Errors: a syntax error, a duplicate primary key, a column name that does
  not exist, and binding past the last parameter. Each sets `conn.err`.
  Error messages differ between databases, so the test prints the error
  code, never the message.
- Reusing a statement: bind, step, `Reset`, bind again, step again.
- `INSERT ... RETURNING id`.
- Many statements prepared and finalized in a loop, to show that nothing
  leaks.

**Done when** `Conformance sqlite::memory:` passes under both models.

**Done.** Learned on the way: the first run found that `DbSqlite.Finalize`
cleared `c.err`, so `Exec` reported a failed `Step` (a duplicate key) as
success. `Finalize` and `Close` now leave `c.err` alone. `src/Db.Mod`'s
conventions and the design's section 2.4 now say so, since the design's
`Exec` depends on it. Two more cases came out of it: "finalize keeps the
error", and SQL holding two statements, which both drivers reject.

## Phase 4: `DbPostgres`

1. **The test cluster.** `test/pg-start.sh` runs `initdb -A trust -U podb`
   into `build/pgdata` (once), then `pg_ctl start` with `-c
   listen_addresses='' -k <abs>/build/pgsock`, and creates the database
   `podb_test`. If `<abs>/build/pgsock/.s.PGSQL.5432` is longer than 107
   bytes (a deep checkout), the script puts the socket in a short directory
   made with `mktemp -d /tmp/podb-XXXXXX` instead, and writes that path to
   `build/pgsock-dir` for the tests and for `pg-stop.sh`. `test/pg-stop.sh` stops the cluster. The default
   `PODB_PG_URL` is `postgres:///podb_test?host=<abs>/build/pgsock&user=podb`.
   libpq takes such a URI as it is, so the driver passes the whole URL to
   `PQconnectdb`.
2. **The externals:** `PQconnectdb`, `PQstatus`, `PQerrorMessage`,
   `PQfinish`, `PQprepare`, `PQexecPrepared`, `PQexec`, `PQresultStatus`,
   `PQresultErrorMessage`, `PQclear`, `PQntuples`, `PQnfields`, `PQfname`,
   `PQftype`, `PQgetvalue`, `PQgetisnull`, `PQgetlength`. `Oid` is an
   `unsigned int`: declare it as `SYSTEM.CARD32`.
3. **`src/DbPostgres.c`**, a small C part for what must not be called
   variadically from Oberon: formatting a `HUGEINT` (`%lld`) and a
   `LONGREAL` (`%.17g`) into a caller's buffer, and parsing both back with
   `strtoll` and `strtod`, reporting whether the parse used the whole string.
4. **`Open`**: `PQconnectdb(url)`. If `PQstatus` is not `CONNECTION_OK`,
   copy `PQerrorMessage` into `Db.lastError`, call `PQfinish`, and return
   NIL.
5. **`Prepare`**: run `Db.Translate(sql, "$", ...)`, then `PQprepare` under a
   unique name (D5), with `nParams` = `params.n` and `paramTypes` = NIL, so
   the server infers the types. Allocate one value slot per parameter.
6. **`Bind*`** (D6): each parameter is a `POINTER TO ARRAY OF CHAR` (NIL
   means NULL), kept in the statement, so the collector keeps it alive until
   it is next bound or finalized. The `paramValues` array handed to libpq is a
   `POINTER TO ARRAY OF SYSTEM.ADDRESS`, filled just before the call. Binding
   an index outside `1..params.n` sets `errRange`.
7. **`Step`**: the first call after `Prepare` or `Reset` runs
   `PQexecPrepared`. `PGRES_TUPLES_OK` sets the row cursor to the first row.
   `PGRES_COMMAND_OK` returns FALSE with no error. Anything else sets
   `errSql` from `PQresultErrorMessage`. Each later call moves the cursor on.
   `Step` returns TRUE while the cursor is below `PQntuples`.
8. **Columns**: `PQgetisnull` gives `typeNull`. Otherwise `PQftype` maps
   `int2`/`int4`/`int8` (OIDs 21, 23, 20) to `typeInt`, `float4`/`float8`/
   `numeric` (700, 701, 1700) to `typeReal`, and everything else, including
   `bool`, to `typeText`. `ColumnInt` and `ColumnReal` parse the text. A
   value that does not parse returns 0 and sets `errRange`.
9. **`Reset`** clears the result and keeps the bindings. **`Finalize`**
   clears the result and deallocates the statement (`PQclosePrepared`). **`Close`**
   calls `PQfinish`.
10. The module body registers the driver under both `postgres` and
    `postgresql`.

**Done when** `DbDemo` and `Conformance` pass against the test cluster
under both models, with the same `Conformance.expected` file as SQLite. If a
case has to differ, the difference goes in the design's section 4 and the
test prints the same line for both databases.

**Done.** Learned on the way:

- No case had to differ: `Conformance` passed against PostgreSQL 18 with
  SQLite's expected file, under both models.
- `DEALLOCATE` fails in a transaction that has already failed, so the
  prepared statement stayed on the server until the connection closed.
  `Finalize` uses `PQclosePrepared` (libpq 17 or later) instead: it is a
  protocol message, and works there. A probe counting
  `pg_prepared_statements` showed no statement left after a failed
  transaction.
- `Conformance` reads `ColumnCount` and `ColumnName` before the first
  `Step`, which a `PGresult` from `PQexecPrepared` cannot answer. `Prepare`
  therefore also calls `PQdescribePrepared` and keeps its result. It gives
  the parameter count, too, so `Prepare` rejects `$n` placeholders that
  `Db.Translate` did not write, as `DbSqlite` does.
- libpq prints the server's notices (`DROP TABLE IF EXISTS`'s "skipping")
  on standard error. Setting a notice processor takes a C callback, so
  `DbPostgres.c` installs one that ignores them.
- `ColumnInt` of text that is not a number is 0 with `errRange`, where
  SQLite gives 0 silently. The design's section 4 records this.
- `Conformance` and `DbDemo` import both drivers, so step 1 of Phase 5 (the
  URL alone picks the driver) is already covered by `make check-postgres`.

## Phase 5: Running both drivers together

1. `make check-postgres` runs `Conformance` with each URL from one binary
   that imports both drivers, which shows that the URL alone selects the
   driver.
2. Finalizers, optional and only if the user wants them: register a
   `GarbageCollectedHeap` finalizer on each connection and statement, so a
   handle the program forgets is still closed. `Close` and `Finalize` stay
   the documented way, and the finalizer is a safety net only. The finalizer
   interface is poc's own, so a driver that uses it is tied to poc.
3. Check, with `-g` and a debugger, or with valgrind on the SQLite tests,
   that no handle or `PGresult` leaks in the `Conformance` run.

**Done**, except step 2. The user decided on 2026-10-27 to leave the
finalizers for later; they are listed under "Later, not scheduled". Learned
on the way:

- Step 1 came with Phase 4: `Conformance` imports both drivers, and `make
  check` and `make check-postgres` run the same binary with each URL.
- Under valgrind, every memory error is in poc's collector
  (`GarbageCollectedHeap.MarkCandidate`, `DrainMarkStack`), which reads
  uninitialised stack words as a conservative collector must.
  `test/valgrind.supp` suppresses those, in those procedures only.
- A forgotten handle is not "definitely lost" to valgrind: its address is
  still in an Oberon record on the collector's heap, which valgrind scans,
  so it is "still reachable". After a `Conformance` run, though, the only
  blocks left are the collector's own three, with either driver. So `make
  check-valgrind` suppresses blocks the collector allocated and counts every
  other block left at exit as a leak. A probe that never finalized a
  PostgreSQL statement failed it; `Conformance` passes.

## Phase 6: Libraries, installation, documentation

1. `make` builds `db`, `db-sqlite` and `db-postgres` with `poc -library`,
   for both size models, with and without `-g`. `make install` runs `poc
   -install-library` for each, or copies into `PREFIX` with `-output-dir`.
   Remember that a library records the poc version that built it, so
   upgrading poc means rebuilding poDB.
2. `README.md`: what poDB is, how to build it, a short example, and how to
   switch databases.
3. `doc/oberon-db-interface.md`: change its status line, replace "Next steps"
   with the real state, give the actual link commands, and record decisions
   D1-D7 and any interface changes.
4. A user's guide section for each driver: its URL forms, how its types are
   mapped, and its limits (BLOBs, `bool` as text, libpq loading the whole
   result into memory).
5. The design document describes `doc/Db.Mod` as it was first written.
   Where `src/Db.Mod` now differs (forward declarations, `HUGEINT`, the
   fixes from Phase 1), say so in the design document. Do not edit the
   original.

**Done.** Learned on the way:

- `poc -library` with `-g` builds only the `-g` variant (`O2-g`, `OC-g`),
  so the `GNUmakefile` builds each library four times. `make install` runs
  `poc -install-library` once per library and variant, into `POCLIBDIR`
  (`~/.local/lib/poc` by default). A program built with `-library-path`
  pointing there links with `-lsqlite3` and `-lpq` without naming them.
- The driver user's guides are in `README.md`. The design document's new
  section 6 records the decisions, the build commands and where `src/Db.Mod`
  differs from `doc/Db.Mod`.

## Later, not scheduled

- Finalizers (Phase 5, step 2): register a `GarbageCollectedHeap` finalizer
  on each connection and statement, so that one the program forgets is
  still closed or finalized when the collector frees it. `Close` and
  `Finalize` stay the documented way, and the finalizer is only a safety
  net. It ties the drivers to poc's own runtime module, and a finalizer runs
  only when the collector runs, so it cannot replace `Close`. Decide with
  the user how it reports an error, and check with `make check-valgrind`
  that it frees what a forgotten handle holds.

- The BSDs: build and test on cymoril, artos and alerik. The library paths
  are `-link -L/usr/local/lib` on FreeBSD and OpenBSD and `/usr/pkg/lib` on
  NetBSD, and the `GNUmakefile` must work with `gmake`.
- Interface additions to discuss with the user: `ColumnIsNull`, the number of
  rows a statement changed, `BindBlob` and `ColumnBlob`, and dollar-quoted
  strings in `Translate`.
- PostgreSQL single-row mode (`PQsetSingleRowMode`), to stream large
  results.
- An ODBC driver (unixODBC), as the design's section 3 mentions.
- VAX/VMS: out of scope. Neither SQLite nor libpq exists for VMS 5.5-2.

## Verification

- `make check` (no server needed) and `make check-postgres`, both under
  `-O2` and `-OC`.
- Each test program prints deterministic lines that are compared with an
  `.expected` file. A test that fails shows the diff.
- No `-strict` check: poc counts `HUGEINT` (D1), `["C"]` procedures and
  `SYSTEM.ADDRESS` as extensions, so every module in `src/` fails it (found
  in Phase 0).
- Build the tests with `-trap-location`, so that a trap names its line.
