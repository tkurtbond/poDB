# A Database-Independent SQL Interface for Peaseblossom Oberon (poc)

**Goal:** write application code once against a single interface, start development on SQLite, and move to PostgreSQL later by changing little more than the connection URL.

**Status:** design plus two Oberon-2 source files (`Db.Mod`, `DbDemo.Mod`). Nothing has been compiled, because poc was not available when these were written. The `DbSqlite` and `DbPostgres` driver modules are not yet written; they need poc's C-calling syntax (see [Next steps](#next-steps)).

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
sqlite:///path/to/file.db
sqlite:///:memory:
postgres://user:pw@host:5432/dbname
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
| `stmt.BindNullByName(n)` / `BindIntByName(n, v)` / `BindRealByName(n, v)` / `BindTextByName(n, v)` | Bind parameters by name (no colon); unknown name sets `conn.err` to `errRange` |
| `stmt.ParamIndex(name): INTEGER` | 1-based number for a parameter name, or 0 |
| `Db.Translate(sql, prefix, VAR out, VAR params): BOOLEAN` | Used by drivers: rewrites placeholders to `?1…` or `$1…` and records names |
| `stmt.Step(): BOOLEAN` | Advance; TRUE if a row is available |
| `stmt.Reset` / `stmt.Finalize` | Rewind, or release the statement |
| `stmt.ColumnCount()` / `ColumnName(i, VAR buf)` / `ColumnType(i)` | Result metadata (columns 0-based) |
| `stmt.ColumnInt(i)` / `ColumnReal(i)` / `ColumnText(i, VAR buf)` | Read column values by number |
| `stmt.ColumnIndex(name): INTEGER` | 0-based number for a column name (case-insensitive), or -1 |
| `stmt.ColumnIntByName(n)` / `ColumnRealByName(n)` / `ColumnTextByName(n, VAR buf)` / `ColumnTypeByName(n)` | Read column values by name; unknown name sets `conn.err` to `errRange` |

Column type codes: `typeNull`, `typeInt`, `typeReal`, `typeText`.
Error codes: `noError`, `errConnect`, `errSql`, `errRange`, `errDriver`.

### 2.4 Conventions every driver must follow

- SQL text uses `?` or `:name` placeholders (never both in one statement). Every driver's `Prepare` passes the SQL through `Db.Translate`, which rewrites placeholders into the numbered form the database wants (`?1`, `?2`, … for SQLite; `$1`, `$2`, … for PostgreSQL) and fills `s.params` with the names. `Prepare` also sets `s.conn`.
- Each driver implements `ColumnName` (and `ColumnCount`), which is all the column-by-name readers need.
- Bind indexes are 1-based; result column indexes are 0-based (see [section 2.7](#27-why-are-parameters-1-based-and-columns-0-based)).
- Each driver operation begins by setting `c.err := noError`. On failure it sets `c.err` to an `err*` code and `c.msg` to the database's message.
- `Finalize` and `Close` are the exceptions: they leave `c.err` as it is, so that `Exec` (`Prepare`, `Step`, `Finalize`) can report an error from `Step`, and so that a loop's error survives finalizing its statement.
- `Step` returns TRUE when a row is available and FALSE when the statement is finished **or** failed. Callers check `c.err` after a stepping loop.
- `ColumnText` copies into the caller's buffer and truncates if the buffer is too small.
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

`Translate` copies the following unchanged: text inside `'...'` and `"..."`, line comments (`--`) and block comments (`/* */`). It does not mistake a PostgreSQL cast such as `x::int` for a parameter. It returns FALSE, and the driver reports an `errSql` error, if the output buffer is too small, there are more than 64 parameters, a name is longer than 31 characters, or `?` and `:name` are mixed in one statement.

Not handled: PostgreSQL dollar-quoted strings (`$$ ... $$`) and PostgreSQL operators that contain a question mark (some JSONB operators). Avoid those in SQL that goes through `Db`, or add handling to `Translate`.

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
| `Bind*` | `sqlite3_bind_null`, `sqlite3_bind_int64`, `sqlite3_bind_double`, `sqlite3_bind_text` |
| `Step` | `sqlite3_step` (`SQLITE_ROW` means a row, `SQLITE_DONE` means finished) |
| `ColumnCount` / `ColumnName` | `sqlite3_column_count` / `sqlite3_column_name` |
| `Column*` | `sqlite3_column_type`, `_int64`, `_double`, `_text` |
| `Reset` / `Finalize` | `sqlite3_reset` / `sqlite3_finalize` |
| `Close` | `sqlite3_close` |
| Error messages | `sqlite3_errmsg` |

### PostgreSQL (libpq)

| `Db` operation | libpq API |
|---|---|
| `Open` | `PQconnectdb` / `PQstatus` |
| `Prepare` | `Db.Translate(sql, "$", …)`, then `PQprepare` with `nParams` = `s.params.n` |
| `Bind*` | Collect parameters as text (or binary) in the driver |
| `Step` | First call runs `PQexecPrepared`; later calls advance a row cursor over the `PGresult` |
| `ColumnCount` / `ColumnName` | `PQnfields` / `PQfname` |
| `Column*` | `PQgetvalue`, `PQgetisnull`, `PQftype` |
| `Finalize` | `PQclear` |
| `Close` | `PQfinish` |
| Error messages | `PQerrorMessage` |

libpq returns the whole result set at once, so the driver must track the current row itself. Unlike SQLite, `Step` does not stream rows from the server by default.

ODBC (for example unixODBC) is an alternative single driver that could cover both databases, at the cost of an extra layer and driver-manager configuration.

## 4. Portability limits a wrapper cannot remove

- **Auto-increment keys.** `INTEGER PRIMARY KEY` auto-increments in SQLite but not in PostgreSQL. The demo supplies ids explicitly. `INSERT ... RETURNING id` works on both (SQLite 3.35 or later).
- **Typing.** SQLite is loosely typed, while PostgreSQL enforces column types and is stricter about booleans, dates and quoting. Keep to plain `INTEGER`, `TEXT` and `REAL` columns while developing on SQLite, and test against PostgreSQL early.
- **Placeholder syntax.** `Db.Translate` hides the `?` / `:name` / `$n` differences, but it is a simple scanner, not a full SQL parser (see section 2.6 for what it skips and what it does not handle).
- **Integer width.** The interface uses `LONGINT` for integer values. Check its width in poc, since both databases support 64-bit integers.
- **Dialect features.** Date and time functions, upsert syntax (`ON CONFLICT`), and concurrency and locking behaviour differ. Stay within the common SQL subset, or isolate dialect-specific statements in one module.
- **Concurrency.** SQLite allows one writer at a time. PostgreSQL's multi-user behaviour may expose problems that never appear in single-user SQLite testing.
- **Result streaming.** As noted above, libpq loads the whole result by default, which matters for very large queries.

## 5. Files

| File | Contents |
|---|---|
| `Db.Mod` | Abstract interface, driver registry, `Open`, placeholder translation, binding by name, columns by name |
| `DbDemo.Mod` | Example program using only `Db`, with named and positional parameters and columns read by name (assumes an Oakwood-style `Out` module; adjust to poc's runtime modules) |

## 6. Next steps

1. Read the "call C" section of poc's `doc/users-guide.md` (and the Reference Guide) to learn the foreign-function syntax: declaring external procedures, linking `-lsqlite3` / `-lpq`, passing strings and pointers.
2. Write `DbSqlite.Mod` first, since it needs no server, and run `DbDemo` against it.
3. Write `DbPostgres.Mod`, including `?` → `$n` rewriting and the row cursor.
4. Add a test suite that runs the same statements against both drivers, to catch dialect differences early.

## Sources

- [tkurtbond/peaseblossom](https://github.com/tkurtbond/peaseblossom)
- [Accessing ODBC Databases from Oberon Programs](https://ssw.jku.at/Research/Reports/Report9.html)
- [An Oberon-2 Binding for the ODMG-93 Standard](https://ssw.jku.at/Research/Papers/Kna98d.html)
- [Optimizing Oberon-2 Compiler](https://www.sourceforge.net/projects/ooc/)
- [Persistent Objects in Java Code (PObjects)](https://sourceforge.net/p/pobjects-java/code)
