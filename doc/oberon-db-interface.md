# A Database-Independent SQL Interface for Peaseblossom Oberon (poc)

**Goal:** write application code once against a single interface, start development on SQLite, and move to PostgreSQL later by changing little more than the connection URL.

**Status:** implemented. `Db`, `DbSqlite` and `DbPostgres` are built with poc 0.9.0 under both of its size models and tested against SQLite and PostgreSQL. The working code is in `src/`, `examples/` and `test/`, and the repository's `README.md` says how to build and use it. `Db.Mod` and `DbDemo.Mod` in this directory are kept as they were first written, before poc was available. [Section 6](#6-state-of-the-implementation) says where the working copies differ from them, and records the decisions made while implementing the design.

---

## 1. Background: what already exists

A search for existing Oberon-2 SQL bindings found only older or niche work, and nothing for SQLite, PostgreSQL or MySQL:

| Item | What it is | Relevance |
|---|---|---|
| Steindl, *Accessing ODBC Databases from Oberon Programs* (JKU Linz, 1996) | Modules `SQL`, `SQLExt` and `ESQL` for ODBC access from Oberon V4 on Windows | Historical precedent; ODBC is a possible route to many databases. Code availability unconfirmed. |
| `libpobj` in OOC (Optimizing Oberon-2 Compiler) | Persistent-object library; the PObjects Java project says it is a port of it and ties into SQL | Possibly useful as a design reference; supported databases unverified. |
| Knasmüller, Oberon-2 binding for ODMG-93 (JKU, 1998) | Binding for object-oriented databases, with OQL | Object database, not SQL; only loosely relevant. |

The repository for poc (`tkurtbond/peaseblossom`) describes an Oberon-2 compiler with an LLVM backend for Linux and the BSDs, plus a separate VAX/VMS backend. Its README says the User's Guide covers calling C and the runtime modules. It mentions no database support, so a binding has to be built on its C-calling facility.

## 2. Design

The design has three layers.

1. **`Db`**: abstract types and a driver registry. Application code imports only this (plus the driver modules it wants linked in).
2. **Drivers** (`DbSqlite`, `DbPostgres`): each extends the abstract types, overrides the abstract procedures, and registers itself under a URL scheme from its module body.
3. **Native client libraries**: `libsqlite3` and `libpq`, reached through poc's C-call mechanism.

### 2.1 Connection URLs

```
sqlite:relative/file.db
sqlite:///path/to/file.db
sqlite::memory:
sqlite:///:memory:
postgres://user:pw@host:5432/dbname
postgresql:///dbname?host=/path/to/socket/dir
```

`Db.Open(url, conn)` reads the scheme before the first `:`, finds the registered driver, and hands the full URL to that driver's `Open`.

Oberon-2 has no dynamic loading, so a driver is only available if its module is imported (and therefore linked). Switching databases means changing the URL and the import line. If both drivers are imported, the URL alone decides at runtime.

### 2.2 Abstract types

Oberon-2 has no interfaces, so abstraction is done with type-bound procedures on record types and type extension.

- `Driver`: `Open(url): Connection`
- `Connection`: `Close`, `Prepare`, plus `Exec`, `Begin`, `Commit`, `Rollback`
- `Statement`: parameter binding, stepping, and column access

`Exec`, `Begin`, `Commit` and `Rollback` are written once in `Db`, on top of `Prepare` and `Step` (the latter three issue the SQL `BEGIN`, `COMMIT` and `ROLLBACK`). A driver therefore only has to implement `Open`, `Close`, `Prepare` and the `Statement` methods.

### 2.3 API summary

| Procedure | Purpose |
|---|---|
| `Db.Open(url, VAR conn): BOOLEAN` | Open a connection; on failure sets `Db.lastError` |
| `Db.Register(driver, scheme)` | Called by a driver at module initialisation |
| `conn.Close` | Close the connection |
| `conn.Prepare(sql, VAR stmt): BOOLEAN` | Prepare a statement |
| `conn.Exec(sql): BOOLEAN` | Run a parameterless statement, ignoring any result row |
| `conn.Begin() / Commit() / Rollback()` | Transactions |
| `stmt.BindNull(i)` / `BindInt(i, v)` / `BindReal(i, v)` / `BindText(i, v)` | Bind parameters by number (1-based) |
| `stmt.BindBlob(i, VAR v, n)` | Bind the `n` bytes `v[0]` … `v[n-1]`, which may include `0X`, as a BLOB (`bytea` on PostgreSQL); `n` outside `0` … `LEN(v)` sets `errRange` |
| `stmt.BindNullByName(n)` / `BindIntByName(n, v)` / `BindRealByName(n, v)` / `BindTextByName(n, v)` / `BindBlobByName(n, VAR v, len)` | Bind parameters by name (no colon); unknown name sets `conn.err` to `errRange` |
| `stmt.ParamIndex(name): INTEGER` | 1-based number for a parameter name, or 0 |
| `Db.Translate(sql, prefix, VAR out, VAR params): BOOLEAN` | Used by drivers: rewrites placeholders to `?1…` or `$1…` and records names |
| `stmt.Step(): BOOLEAN` | Advance; TRUE if a row is available |
| `stmt.Reset` / `stmt.Finalize` | Rewind, or release the statement |
| `stmt.Changes(): HUGEINT` | Rows the last run inserted, updated or deleted, once `Step` has returned FALSE; 0 before then, after `Reset`, and for any other statement |
| `stmt.ColumnCount()` / `ColumnName(i, VAR buf)` / `ColumnType(i)` | Result metadata (columns 0-based) |
| `stmt.ColumnInt(i)` / `ColumnReal(i)` / `ColumnText(i, VAR buf)` | Read column values by number |
| `stmt.ColumnBlob(i, VAR buf): LONGINT` | Copy as many of the value's bytes as fit into `buf` (no `0X` added) and return its whole length, so a caller can allocate a larger buffer and read it again; NULL has length 0 |
| `stmt.ColumnIsNull(i): BOOLEAN` | TRUE if the value is NULL; written once in `Db`, on `ColumnType` |
| `stmt.ColumnIndex(name): INTEGER` | 0-based number for a column name (case-insensitive), or -1 |
| `stmt.ColumnIntByName(n)` / `ColumnRealByName(n)` / `ColumnTextByName(n, VAR buf)` / `ColumnBlobByName(n, VAR buf)` / `ColumnTypeByName(n)` / `ColumnIsNullByName(n)` | Read column values by name; unknown name sets `conn.err` to `errRange` (and `ColumnIsNullByName` returns TRUE) |

Column type codes: `typeNull`, `typeInt`, `typeReal`, `typeText`, `typeBlob`.
Error codes: `noError`, `errConnect`, `errSql`, `errRange`, `errDriver`.

### 2.4 Conventions every driver must follow

- SQL text uses `?` or `:name` placeholders (never both in one statement). Every driver's `Prepare` passes the SQL through `Db.Translate`, which rewrites placeholders into the numbered form the database wants (`?1`, `?2`, … for SQLite; `$1`, `$2`, … for PostgreSQL) and fills `s.params` with the names. `Prepare` also sets `s.conn`.
- Each driver implements `ColumnName` (and `ColumnCount`), which is all the column-by-name readers need.
- Bind indexes are 1-based; result column indexes are 0-based (see [section 2.7](#27-why-are-parameters-1-based-and-columns-0-based)).
- Each driver operation begins by setting `c.err := noError`. On failure it sets `c.err` to an `err*` code and `c.msg` to the database's message.
- `Finalize` and `Close` are the exceptions: they leave `c.err` as it is, so that `Exec` (`Prepare`, `Step`, `Finalize`) can report an error from `Step`, and so that a loop's error survives finalizing its statement.
- `Step` returns TRUE when a row is available and FALSE when the statement is finished **or** failed. Callers check `c.err` after a stepping loop.
- `ColumnText` copies into the caller's buffer and truncates if the buffer is too small. `ColumnBlob` does too, and returns the value's whole length.
- `Changes` counts only the rows the statement itself inserted, updated or deleted, and only once `Step` has returned FALSE. `Reset` sets it back to 0. There is no count for `Exec`, which discards its statement; prepare the statement to get one.
- Errors are reported by status code and message, since Oberon-2 has no exceptions.

### 2.5 Example usage

```oberon
IMPORT Db, DbSqlite;      (* swap or add DbPostgres here *)

IF ~Db.Open("sqlite:///demo.db", conn) THEN (* report Db.lastError *) END;

IF ~conn.Prepare("SELECT id, name FROM person WHERE age >= :min_age ORDER BY id", st) THEN
  (* report conn.msg *)
END;
st.BindIntByName("min_age", 40);      (* or, with a ? placeholder: st.BindInt(1, 40) *)
WHILE st.Step() DO
  st.ColumnText(1, name);
  (* ... use st.ColumnInt(0) and name ... *)
END;
IF conn.err # Db.noError THEN (* report conn.msg *) END;
st.Finalize;
conn.Close
```

`DbDemo.Mod` is a complete version of this: create table, transactional inserts using named parameters, and a select using a positional parameter. To move it to PostgreSQL, change the URL and the driver import.

### 2.6 Named parameters and placeholder translation

Named parameters are written once, in `Db`, so the drivers get them without extra work:

1. `Db.Translate` scans the SQL once. Each `:name` becomes `?n` (SQLite) or `$n` (PostgreSQL), where `n` is the parameter's number, assigned in order of first appearance. A name that appears several times shares one number, so it is bound once.
2. The names are stored in `s.params`. `BindIntByName("min_age", 40)` looks the name up and calls the driver's numbered `BindInt`.
3. Plain `?` placeholders are numbered in order of appearance, so positional statements go through the same path.

`Translate` copies the following unchanged: text inside `'...'` and `"..."`, PostgreSQL's dollar-quoted strings (`$$ ... $$` and `$tag$ ... $tag$`), line comments (`--`) and block comments (`/* */`). It does not mistake a PostgreSQL cast such as `x::int` for a parameter. A dollar quote opens only at a `$` that does not follow a letter, digit, `_` or `$`, so `$1` and the `$` inside an identifier such as `a$b` are left alone. An unterminated quote, string or comment runs to the end of the SQL. `Translate` returns FALSE, and the driver reports an `errSql` error, if the output buffer is too small, there are more than 64 parameters, a name or a dollar quote's tag is longer than 31 characters, or `?` and `:name` are mixed in one statement.

Not handled: PostgreSQL operators that contain a question mark (some JSONB operators, such as `?|`). Avoid those in SQL that goes through `Db`, or use the equivalent functions (`jsonb_exists_any`).

SQLite supports `:name` natively, but the translation is used for both backends so that the rules are identical.

### 2.7 Why are parameters 1-based and columns 0-based?

I copied the convention from the two C APIs, so that the drivers can pass indexes straight through:

- **Parameters are 1-based** because the SQL text numbers them that way: `?1` and `$1` in the statement refer to the first parameter. SQLite's `sqlite3_bind_*` functions and libpq's `$n` placeholders both start at 1, so `BindInt(1, …)` matches `$1` or `?1` in the statement.
- **Columns are 0-based** because a result row is addressed like an array: `sqlite3_column_*` and `PQgetvalue` both start at 0.

It is an inconsistency in the interface, and it is easy to trip over. Binding by name and reading columns by name both sidestep it. If you prefer, the interface could use one base for both, at the cost of a `+1` or `-1` inside every driver call. The choice is a matter of taste rather than a technical requirement.

### 2.8 Reading columns by name

Column values can be read by number or by name:

```oberon
st.ColumnTextByName("name", name);
id := st.ColumnIntByName("id");
```

Like binding by name, these are written once in `Db`, on top of two driver methods: `ColumnCount` and `ColumnName`. `ColumnIndex(name)` searches the column names and the typed reader then calls the driver's numbered reader.

- **Case-insensitive matching.** PostgreSQL folds unquoted names to lower case, while SQLite keeps them as written (`SELECT Id` gives a column called `Id` in SQLite and `id` in PostgreSQL). Case-insensitive matching means the same program works on both.
- **Duplicate names.** If a join returns two columns with the same name, the first one is used. Alias the columns in the SQL (`a.id AS a_id`) if you need both.
- **Errors.** An unknown name sets `conn.err` to `errRange` and returns 0 or an empty string. `ColumnTypeByName` returns `typeNull` in that case, so check `conn.err` to tell that apart from a real NULL column.
- **Cost.** Each by-name call searches the column names. That is fine for ordinary use. In a loop over a large result, call `ColumnIndex` once before the loop and use the numbered readers inside it.

## 3. What each driver has to do

### SQLite

| `Db` operation | SQLite C API |
|---|---|
| `Open` | `sqlite3_open_v2` |
| `Prepare` | `Db.Translate(sql, "?", …)`, then `sqlite3_prepare_v2` |
| `Bind*` | `sqlite3_bind_null`, `sqlite3_bind_int64`, `sqlite3_bind_double`, `sqlite3_bind_text`, `sqlite3_bind_blob` (`sqlite3_bind_zeroblob` for 0 bytes) |
| `Step` | `sqlite3_step` (`SQLITE_ROW` means a row, `SQLITE_DONE` means finished) |
| `Changes` | `sqlite3_changes64`, if `sqlite3_total_changes64` moved during the run (otherwise the count is another statement's) |
| `ColumnCount` / `ColumnName` | `sqlite3_column_count` / `sqlite3_column_name` |
| `Column*` | `sqlite3_column_type`, `_int64`, `_double`, `_text`, `_blob` and `_bytes` |
| `Reset` / `Finalize` | `sqlite3_reset` / `sqlite3_finalize` |
| `Close` | `sqlite3_close` |
| Error messages | `sqlite3_errmsg` |

### PostgreSQL (libpq)

| `Db` operation | libpq API |
|---|---|
| `Open` | `PQconnectdb` / `PQstatus` |
| `Prepare` | `Db.Translate(sql, "$", …)`, then `PQprepare` with `nParams` = `s.params.n`, under a name unique on the connection (`podb_1`, `podb_2`, …), then `PQdescribePrepared` |
| `Bind*` | Collect parameters as text in the driver; numbers are formatted to text. `BindBlob`'s bytes go in binary format, the one exception to D6 |
| `Step` | First call runs `PQexecPrepared`; later calls advance a row cursor over the `PGresult` |
| `ColumnCount` / `ColumnName` | `PQnfields` / `PQfname` on the description, so they work before the first `Step` |
| `Changes` | `PQcmdTuples`, when `PQcmdStatus` is an `INSERT`, `UPDATE`, `DELETE` or `MERGE` |
| `Column*` | `PQgetvalue`, `PQgetisnull`, `PQftype`; numbers are parsed from text, and `ColumnBlob` unescapes a `bytea` with `PQunescapeBytea` |
| `Finalize` | `PQclear`, then `PQclosePrepared` (libpq 17 or later), which deallocates the statement even in a failed transaction, where `DEALLOCATE` is refused |
| `Close` | `PQfinish` |
| Error messages | `PQerrorMessage` |

libpq returns the whole result set at once, so the driver must track the current row itself. Unlike SQLite, `Step` does not stream rows from the server by default.

ODBC (for example unixODBC) is an alternative single driver that could cover both databases, at the cost of an extra layer and driver-manager configuration.

## 4. Portability limits a wrapper cannot remove

- **Auto-increment keys.** `INTEGER PRIMARY KEY` auto-increments in SQLite but not in PostgreSQL. The demo supplies ids explicitly. `INSERT ... RETURNING id` works on both (SQLite 3.35 or later).
- **Typing.** SQLite is loosely typed, while PostgreSQL enforces column types and is stricter about booleans, dates and quoting. Keep to plain `INTEGER`, `TEXT` and `REAL` columns while developing on SQLite, and test against PostgreSQL early. For binary data declare the column `BYTEA`: it is PostgreSQL's type, and SQLite accepts the name and stores a bound BLOB unchanged. `BindBlob` sends binary data, which suits only such a column.
- **Placeholder syntax.** `Db.Translate` hides the `?` / `:name` / `$n` differences, but it is a simple scanner, not a full SQL parser (see section 2.6 for what it skips and what it does not handle).
- **Integer width.** The interface uses `HUGEINT` for integer values, which is 64 bits in poc under both size models, as are both databases' largest integers.
- **Reading a value as the wrong type.** SQLite converts any value to the type asked for: `ColumnInt` of the text `'abc'` is 0, with no error. The PostgreSQL driver parses the value's text, so `ColumnInt` of text that is not a number is 0 with `errRange`. Both truncate a real number toward zero for `ColumnInt`. A PostgreSQL `boolean` reads as the text `t` or `f`, where SQLite stores 1 or 0.
- **Dialect features.** Date and time functions, upsert syntax (`ON CONFLICT`), and concurrency and locking behaviour differ. Stay within the common SQL subset, or isolate dialect-specific statements in one module.
- **Concurrency.** SQLite allows one writer at a time. PostgreSQL's multi-user behaviour may expose problems that never appear in single-user SQLite testing.
- **Result streaming.** As noted above, libpq loads the whole result by default, which matters for very large queries.

## 5. Files

| File | Contents |
|---|---|
| `Db.Mod` | Abstract interface, driver registry, `Open`, placeholder translation, binding by name, columns by name |
| `DbDemo.Mod` | Example program using only `Db`, with named and positional parameters and columns read by name (assumes an Oakwood-style `Out` module; adjust to poc's runtime modules) |

Both are the original design and are not built. The implementation is elsewhere in the repository:

| File | Contents |
|---|---|
| `src/Db.Mod` | `Db`, started as a copy of `doc/Db.Mod` |
| `src/DbCStrings.Mod` | Copies a C string into an Oberon buffer, for the drivers |
| `src/DbSqlite.Mod` | The SQLite driver |
| `src/DbPostgres.Mod`, `src/DbPostgres.c` | The PostgreSQL driver, and its C part (`snprintf`, `strtoll`, the notice processor) |
| `examples/DbDemo.Mod` | `DbDemo`, started as a copy of `doc/DbDemo.Mod` |
| `test/` | `Db`'s unit tests (on a mock driver), the conformance test both drivers pass, and the PostgreSQL test cluster's scripts |

## 6. State of the implementation

The three steps that were planned here are done: `DbSqlite` was written first and runs `DbDemo`, `DbPostgres` followed, and one conformance test runs the same statements against both drivers and expects the same output from each.

### 6.1 Building and linking

poDB is built as three poc libraries, `db` (`Db`, `DbCStrings`), `db-sqlite` (`DbSqlite`) and `db-postgres` (`DbPostgres`). The driver libraries are built with `-link -lsqlite3` and `-link -lpq`, which poc records, so a program that uses them is linked with the C library without naming it:

```
poc -library db src/Db.Mod src/DbCStrings.Mod
poc -library-path . -link -lsqlite3 -library db-sqlite src/DbSqlite.Mod
poc -library-path . -link -lpq -library db-postgres src/DbPostgres.Mod
poc -library-path <dir> DbDemo.Mod
```

poc compiles `DbPostgres.c` as `DbPostgres`'s C part because it lies beside `DbPostgres.Mod`. A program built from the sources rather than the libraries names the C libraries itself: `poc -import-path src -link -lsqlite3 -link -lpq DbDemo.Mod`. The repository's `GNUmakefile` builds each library under `-O2` and `-OC`, with and without `-g`, and `make install` installs them.

### 6.2 Decisions

These were decided while planning the implementation (on 2026-10-27):

| | Decision |
|---|---|
| D1 | 64-bit integer values are `HUGEINT` in the public interface: `BindInt`, `BindIntByName`, `ColumnInt`, `ColumnIntByName`. `LONGINT` is only 32 bits under poc's default size model. |
| D2 | SQLite URLs are `sqlite:<path>`: `sqlite:demo.db` is relative, `sqlite:///abs/file.db` is absolute, and `sqlite::memory:` or `sqlite:///:memory:` is an in-memory database. |
| D3 | There are three poc libraries, `db`, `db-sqlite` and `db-postgres`, so a program that uses one database does not link the other's C library. |
| D4 | Parameters are numbered from 1 and columns from 0, as in section 2.7. |
| D5 | Each PostgreSQL prepared statement gets a name unique on its connection, and `Finalize` deallocates it with `PQclosePrepared` (libpq 17 or later). |
| D6 | PostgreSQL parameters and results use text format. |
| D7 | `doc/Db.Mod` and `doc/DbDemo.Mod` stay unchanged as part of the design. |

### 6.3 Where `src/Db.Mod` differs from `doc/Db.Mod`

- **`HUGEINT`** for integer values (D1), in the four procedures listed above.
- **`Finalize` and `Close` leave `c.err` as it is.** As first written, `Exec` lost an error from `Step` when it finalized the statement. Section 2.4 now states the rule.
- **Forward declarations.** poc requires a procedure, type-bound ones included, to be declared before it is called, so `Db.Mod` declares `Step` and `Finalize` with `PROCEDURE ^` before `Exec` uses them.
- **`LONGINT` indexes into character arrays.** Under poc's default size model `INTEGER` stops at 32767, and SQL text or a value can be longer. `Translate` and the name lookups index with `LONGINT`.
- **Column names up to 127 characters** (`maxColumnName`), not 63. PostgreSQL's limit is 63 bytes, but SQLite has none, and an expression gives a long name.
- **Additions to the interface** (2026-10-27): `typeBlob`, `BindBlob`, `ColumnBlob`, `Changes`, `ColumnIsNull`, and their `ByName` forms. `Translate` handles dollar-quoted strings.
- **`Db.Open`** checks the scheme's length before copying it, rejects a URL with no scheme, sets `lastError` to `""` on success, and sets it to a message if a driver returns NIL without one.

`examples/DbDemo.Mod` differs from `doc/DbDemo.Mod` only in its use of `HUGEINT`, in taking an optional URL from the command line, in importing both drivers, and in deleting the table's rows first so that it can run twice on one file.

### 6.4 Not done

- Finalizers that close a connection or statement the program forgot. They would tie the drivers to poc's `GarbageCollectedHeap` and are left for later.
- Streaming large PostgreSQL results (`PQsetSingleRowMode`).
- An ODBC driver, and the BSDs.

## Sources

- [tkurtbond/peaseblossom](https://github.com/tkurtbond/peaseblossom)
- [Accessing ODBC Databases from Oberon Programs](https://ssw.jku.at/Research/Reports/Report9.html)
- [An Oberon-2 Binding for the ODMG-93 Standard](https://ssw.jku.at/Research/Papers/Kna98d.html)
- [Optimizing Oberon-2 Compiler](https://www.sourceforge.net/projects/ooc/)
- [Persistent Objects in Java Code (PObjects)](https://sourceforge.net/p/pobjects-java/code)
