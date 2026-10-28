# poDB

poDB is a database-independent SQL interface for Oberon-2, written for
**poc**, the Peaseblossom Oberon Compiler. A program is written once against
module `Db`. It can start out on SQLite and move to PostgreSQL by changing
the connection URL and the driver it imports.

- `Db`: connections, prepared statements, parameters bound by number or by
  `:name`, and columns read by number or by name.
- `DbSqlite`: the SQLite driver, on `libsqlite3`.
- `DbPostgres`: the PostgreSQL driver, on `libpq`.

The design, and the reasons for it, are in
[`doc/oberon-db-interface.md`](doc/oberon-db-interface.md).

## Requirements

- poc 0.9.0 or later (the Fedora package `peaseblossom`).
- For `DbSqlite`: SQLite 3.37 or later and its development files
  (`sqlite-devel`). The driver uses `sqlite3_changes64`, which 3.37 added.
- For `DbPostgres`: libpq 17 or later and its development files
  (`libpq-devel`). The driver uses `PQclosePrepared`, which libpq 17 added.
- For `make check-postgres`: `postgresql-server`, for `initdb` and `pg_ctl`.
  The tests make and run a private cluster of their own, under `build/`.
- For `make check-valgrind`: valgrind.

## Building and installing

```
make                 # the libraries, under -O2 and -OC, with and without -g
make check           # the tests that need no server
make check-postgres  # the PostgreSQL tests, on a throwaway local cluster
make install         # into ~/.local/lib/poc
```

`make` builds three poc libraries, each in four variants (`O2`, `O2-g`,
`OC`, `OC-g`) under `build/lib`:

| Library | Modules | Links with |
|---|---|---|
| `db` | `Db`, `DbCStrings` | nothing |
| `db-sqlite` | `DbSqlite` | `-lsqlite3` |
| `db-postgres` | `DbPostgres` | `-lpq` |

`make install` installs them in `$(POCLIBDIR)`, which is
`$(PREFIX)/lib/poc`, and `PREFIX` is `~/.local` by default:

```
make install PREFIX=/opt/podb
```

A library records the poc version that built it. After upgrading poc, run
`make clean install`.

## Using it

Import `Db` and the driver for each database the program may use. Importing
a driver is what registers it, so the import is needed even though the
program never names the driver:

```oberon
MODULE People;
(* Print everyone aged 40 or over. *)

IMPORT Db, Out, DbSqlite;   (* DbSqlite registers the "sqlite" scheme *)

VAR conn: Db.Connection; st: Db.Statement; name: ARRAY 64 OF CHAR;

BEGIN
  IF ~Db.Open("sqlite:people.db", conn) THEN
    Out.String(Db.lastError); Out.Ln; HALT(1)
  END;
  IF conn.Prepare("SELECT id, name FROM person WHERE age >= :min_age ORDER BY id", st) THEN
    st.BindIntByName("min_age", 40);
    WHILE st.Step() DO
      st.ColumnTextByName("name", name);
      Out.Int(st.ColumnIntByName("id"), 0); Out.String("  "); Out.String(name); Out.Ln
    END;
    st.Finalize
  END;
  IF conn.err # Db.noError THEN Out.String(conn.msg); Out.Ln END;
  conn.Close
END People.
```

Build it against the installed libraries. poc finds the libraries a program
needs from the modules it imports, and links each with the C library it
recorded:

```
poc -library-path ~/.local/lib/poc People.Mod
poc -OC -library-path ~/.local/lib/poc People.Mod
```

The program and every library it uses must share one size model: `-O2` (the
default) or `-OC`. Integer values in `Db` are `HUGEINT`, which is 64 bits
under both.

`examples/DbDemo.Mod` is a longer example: it creates a table, inserts rows
in a transaction with named parameters, and selects with a positional one.

### Moving to PostgreSQL

Change the URL, and import `DbPostgres` instead of, or as well as,
`DbSqlite`:

```oberon
IMPORT Db, Out, DbPostgres;
...
  IF ~Db.Open("postgres://user@host/dbname", conn) THEN
```

A program that imports both drivers chooses one at run time from the URL's
scheme. `DbDemo` does this: `DbDemo sqlite::memory:` and `DbDemo
postgres:///dbname` run the same code on each database.

The SQL has to suit both databases, too. The design's section 4 lists what
poDB cannot hide: auto-increment keys, typing, dialect features.

## Conventions

- Parameters are numbered from 1, columns from 0. Binding and reading by
  name avoid the difference.
- SQL uses `?` or `:name` placeholders, not both in one statement. `Db`
  rewrites them for each database.
- `Reset` keeps the values bound to the parameters, so bind again only
  those that change.
- Every operation sets `conn.err` and `conn.msg`. `Step` returns FALSE both
  when the rows run out and when it fails, so check `conn.err` after a
  stepping loop.
- `Finalize` every statement and `Close` every connection. The collector
  frees the Oberon records, but not the database's handles.
- `ColumnText` truncates a value to fit the buffer, and always ends it with
  `0X`. `ColumnBlob` truncates too, adds no `0X`, and returns the value's
  whole length.
- `Changes` gives the number of rows a prepared statement's last run
  inserted, updated or deleted, once `Step` has returned FALSE.
  `conn.Changes()` gives the count of the last statement to finish, so after
  `conn.Exec(...)` it is the rows `Exec` changed. `Exec` runs its statement
  to the end, so an `UPDATE ... RETURNING` is counted whole.
- For binary data, declare the column `BYTEA`, bind with `BindBlob` and read
  with `ColumnBlob`. SQLite accepts the type name and stores the bytes
  unchanged.
- For booleans, declare the column `BOOLEAN`, bind with `BindBool` and read
  with `ColumnBool`. Both databases see 1 or 0.
- For dates and times, declare the column `DATE` or `TIMESTAMP` (not
  `TIMESTAMPTZ`), bind a `Db.DateTime` with `BindDate` or `BindDateTime`,
  and read it with `ColumnDateTime`. Values travel as ISO 8601 text
  (`2026-10-28 14:30:05`), which SQLite stores as it is and which sorts in
  date order. `DateTime` has no time zone, so keep the values in UTC. The
  PostgreSQL driver puts its session in UTC, so a `TIMESTAMPTZ` column
  works too: it reads in UTC, and a bound time stamp is taken as UTC.
  An invalid date, such as February 30, sets `errRange`.
- For a large result, prepare the query with `conn.PrepareQuery(sql, rows,
  st)` instead of `conn.Prepare(sql, st)`. The database then reads its rows
  `rows` at a time, other statements can run while it is stepped, and
  stopping early costs nothing. Step it only between `conn.Begin()` and
  `conn.Commit()` (or `Rollback()`). On PostgreSQL its rows come from a
  cursor, which the end of the transaction closes.

## The SQLite driver

**URLs.** `Db.Open` takes:

| URL | Database |
|---|---|
| `sqlite:demo.db` | the file `demo.db`, relative to the current directory |
| `sqlite:///abs/file.db` | the file `/abs/file.db` |
| `sqlite::memory:` or `sqlite:///:memory:` | a new in-memory database |

The file is created if it does not exist.

**Types.** A value reads as SQLite stored it: `INTEGER` as `typeInt`, `REAL`
as `typeReal`, `TEXT` as `typeText`, a BLOB as `typeBlob`, NULL as
`typeNull`. `ColumnInt`,
`ColumnReal` and `ColumnText` convert any value as SQLite does, without an
error: `ColumnInt` of the text `'abc'` is 0, and of `2.7` is 2.

**Limits.**

- `ColumnText` of a BLOB gives its bytes up to the first `0X`. Use
  `ColumnBlob`.
- `Prepare` takes one SQL statement. Text after the first statement's end is
  an error, as on PostgreSQL.

## The PostgreSQL driver

**URLs.** The schemes `postgres` and `postgresql` both select the driver,
which hands the whole URL to libpq's `PQconnectdb`. Anything libpq accepts
in a URI works, including the environment variables it reads (`PGHOST`,
`PGUSER`, `PGPASSWORD` and so on):

| URL | Connects to |
|---|---|
| `postgres://user:pw@host:5432/dbname` | `dbname` on `host` over TCP |
| `postgres:///dbname` | `dbname` on the default local socket |
| `postgres:///dbname?host=/path/to/socket/dir` | `dbname` on a socket in that directory |

Avoid a password in a URL written into a program. Use `~/.pgpass` or
`PGPASSWORD` instead.

**Types.** Values travel as text both ways. Numbers are formatted as text to
bind them and parsed from text to read them. A column's type comes from the
type the server declares for it:

| PostgreSQL type | `ColumnType` |
|---|---|
| `smallint`, `integer`, `bigint` | `typeInt` |
| `boolean` | `typeInt`, reading as 1 or 0 |
| `real`, `double precision`, `numeric` | `typeReal` |
| `bytea` | `typeBlob` |
| NULL, any type | `typeNull` |
| anything else | `typeText` |

`ColumnInt` truncates a real value toward zero, as SQLite does. Unlike
SQLite, `ColumnInt` or `ColumnReal` of text that is not a number gives 0
with `conn.err` set to `errRange`.

**Limits.**

- The driver sets `DateStyle` to `ISO` and `TimeZone` to `UTC` when it
  connects, so the session's SQL works in UTC: `now()` displays in UTC,
  and `date_trunc('day', ...)` of a `timestamptz` cuts days at UTC
  midnight. After a `SET TimeZone` of its own, a program's `timestamptz`
  values read with an offset (`+02`) that `ColumnDateTime` rejects with
  `errRange`.
- `ColumnText` of a `bytea` gives PostgreSQL's hex form (`\x...`). Use
  `ColumnBlob`.
- `BindBlob` sends its bytes in binary format, so its parameter should be a
  `bytea`.
- A `numeric` reads as `typeReal`, so `ColumnReal` loses digits beyond a
  `LONGREAL`'s. Read it with `ColumnText` to keep them all.
- A query's rows arrive in chunks of 100, and `Step` holds one chunk at a
  time. But while they arrive the connection can do nothing else, so a
  statement run inside a loop over another's rows makes the driver read
  the rest of the outer result into memory. For a very large result, use
  `PrepareQuery`, or run the inner statements on a second connection.
- `Reset` or `Finalize` partway through a `Prepare`d statement's result
  reads and discards the rest of it. A `PrepareQuery` statement's are
  free.
- `PrepareQuery` takes only a query, a `SELECT` or `VALUES`: an
  `INSERT ... RETURNING` fails when it is prepared. Stepped outside a
  transaction it fails with `errSql`. After the transaction ends, it gives
  the rest of the batch it holds, then fails.
- A query that fails partway gives the rows before the error, then the
  error, as on SQLite.
- The server's notices, such as `DROP TABLE IF EXISTS`'s "skipping", are
  discarded.
- Operators containing `?` (some of JSONB's, such as `?|`) confuse the
  placeholder translation. Avoid them in SQL given to `Db`, or use the
  equivalent functions (`jsonb_exists_any`).

## License

poDB is under the BSD 3-Clause License, as Peaseblossom is. See
[`LICENSE`](LICENSE).
