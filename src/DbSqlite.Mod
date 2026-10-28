MODULE DbSqlite;
(* The SQLite driver for Db.  Importing this module registers it under the
   scheme "sqlite", so Db.Open accepts URLs of these forms:

     sqlite:demo.db          the file demo.db, relative to the current directory
     sqlite:///abs/file.db   the file /abs/file.db
     sqlite::memory:         a new in-memory database
     sqlite:///:memory:      the same

   The database file is created if it does not exist.  A statement is one SQL
   statement: Prepare rejects text that goes on after the first statement's
   end, as PostgreSQL does.  A BLOB value reads as typeBlob. *)

IMPORT SYSTEM, Db, DbCStrings;

CONST
  (* sqlite3.h *)
  sqliteOk = 0;
  sqliteRange = 25;
  sqliteRow = 100;
  sqliteDone = 101;
  openReadWrite = 2H;
  openCreate = 4H;
  integerColumn = 1;
  floatColumn = 2;
  textColumn = 3;
  blobColumn = 4;
  transient = -1;   (* SQLITE_TRANSIENT: SQLite copies the value at once *)

TYPE
  Connection = POINTER TO ConnectionDesc;
  ConnectionDesc = RECORD (Db.ConnectionDesc)
    db: SYSTEM.ADDRESS   (* sqlite3 *, or 0 once closed *)
  END;

  Statement = POINTER TO StatementDesc;
  StatementDesc = RECORD (Db.StatementDesc)
    db: SYSTEM.ADDRESS;     (* the connection's handle, for sqlite3_errmsg *)
    stmt: SYSTEM.ADDRESS;   (* sqlite3_stmt *, or 0 once finalized *)
    onRow: BOOLEAN;         (* the last Step returned a row *)
    before: HUGEINT;        (* sqlite3_total_changes64 when this run started *)
    changes: HUGEINT        (* the rows this run changed, once it is done *)
  END;

  Driver = POINTER TO DriverDesc;
  DriverDesc = RECORD (Db.DriverDesc) END;

  Text = POINTER TO ARRAY OF CHAR;

VAR
  driver: Driver;


(* ---- libsqlite3 ---- *)

PROCEDURE ["C", "sqlite3_open_v2"] OpenDatabase (filename: SYSTEM.ADDRESS;
    db: SYSTEM.ADDRESS; flags: SYSTEM.INT32; vfs: SYSTEM.ADDRESS): SYSTEM.INT32;
PROCEDURE ["C", "sqlite3_close_v2"] CloseDatabase (db: SYSTEM.ADDRESS): SYSTEM.INT32;
PROCEDURE ["C", "sqlite3_errmsg"] ErrorMessage (db: SYSTEM.ADDRESS): SYSTEM.ADDRESS;
PROCEDURE ["C", "sqlite3_prepare_v2"] PrepareStatement (db, sql: SYSTEM.ADDRESS;
    bytes: SYSTEM.INT32; stmt, tail: SYSTEM.ADDRESS): SYSTEM.INT32;
PROCEDURE ["C", "sqlite3_bind_parameter_count"] ParameterCount (stmt: SYSTEM.ADDRESS): SYSTEM.INT32;
PROCEDURE ["C", "sqlite3_bind_null"] BindNullValue (stmt: SYSTEM.ADDRESS;
    i: SYSTEM.INT32): SYSTEM.INT32;
PROCEDURE ["C", "sqlite3_bind_int64"] BindInt64 (stmt: SYSTEM.ADDRESS;
    i: SYSTEM.INT32; v: SYSTEM.INT64): SYSTEM.INT32;
PROCEDURE ["C", "sqlite3_bind_double"] BindDouble (stmt: SYSTEM.ADDRESS;
    i: SYSTEM.INT32; v: LONGREAL): SYSTEM.INT32;
PROCEDURE ["C", "sqlite3_bind_text"] BindTextValue (stmt: SYSTEM.ADDRESS;
    i: SYSTEM.INT32; text: SYSTEM.ADDRESS; bytes: SYSTEM.INT32;
    destructor: SYSTEM.ADDRESS): SYSTEM.INT32;
PROCEDURE ["C", "sqlite3_bind_blob"] BindBlobValue (stmt: SYSTEM.ADDRESS;
    i: SYSTEM.INT32; blob: SYSTEM.ADDRESS; bytes: SYSTEM.INT32;
    destructor: SYSTEM.ADDRESS): SYSTEM.INT32;
PROCEDURE ["C", "sqlite3_bind_zeroblob"] BindZeroBlob (stmt: SYSTEM.ADDRESS;
    i: SYSTEM.INT32; bytes: SYSTEM.INT32): SYSTEM.INT32;
PROCEDURE ["C", "sqlite3_stmt_busy"] StatementBusy (stmt: SYSTEM.ADDRESS): SYSTEM.INT32;
PROCEDURE ["C", "sqlite3_changes64"] ChangesOf (db: SYSTEM.ADDRESS): SYSTEM.INT64;
PROCEDURE ["C", "sqlite3_total_changes64"] TotalChanges (db: SYSTEM.ADDRESS): SYSTEM.INT64;
PROCEDURE ["C", "sqlite3_step"] StepStatement (stmt: SYSTEM.ADDRESS): SYSTEM.INT32;
PROCEDURE ["C", "sqlite3_reset"] ResetStatement (stmt: SYSTEM.ADDRESS): SYSTEM.INT32;
PROCEDURE ["C", "sqlite3_clear_bindings"] ClearBindings (stmt: SYSTEM.ADDRESS): SYSTEM.INT32;
PROCEDURE ["C", "sqlite3_finalize"] FinalizeStatement (stmt: SYSTEM.ADDRESS): SYSTEM.INT32;
PROCEDURE ["C", "sqlite3_column_count"] ColumnCountOf (stmt: SYSTEM.ADDRESS): SYSTEM.INT32;
PROCEDURE ["C", "sqlite3_column_name"] ColumnNameOf (stmt: SYSTEM.ADDRESS;
    i: SYSTEM.INT32): SYSTEM.ADDRESS;
PROCEDURE ["C", "sqlite3_column_type"] ColumnTypeOf (stmt: SYSTEM.ADDRESS;
    i: SYSTEM.INT32): SYSTEM.INT32;
PROCEDURE ["C", "sqlite3_column_int64"] ColumnInt64 (stmt: SYSTEM.ADDRESS;
    i: SYSTEM.INT32): SYSTEM.INT64;
PROCEDURE ["C", "sqlite3_column_double"] ColumnDouble (stmt: SYSTEM.ADDRESS;
    i: SYSTEM.INT32): LONGREAL;
PROCEDURE ["C", "sqlite3_column_text"] ColumnTextOf (stmt: SYSTEM.ADDRESS;
    i: SYSTEM.INT32): SYSTEM.ADDRESS;
PROCEDURE ["C", "sqlite3_column_blob"] ColumnBlobOf (stmt: SYSTEM.ADDRESS;
    i: SYSTEM.INT32): SYSTEM.ADDRESS;
PROCEDURE ["C", "sqlite3_column_bytes"] ColumnBytes (stmt: SYSTEM.ADDRESS;
    i: SYSTEM.INT32): SYSTEM.INT32;


(* ---- Helpers ---- *)

PROCEDURE SetSqliteError (c: Db.Connection; code: INTEGER; db: SYSTEM.ADDRESS);
(* Set c's error to code, with SQLite's message for db. *)
  VAR msg: Db.Message;
BEGIN
  DbCStrings.Copy(ErrorMessage(db), msg);
  Db.SetError(c, code, msg)
END SetSqliteError;

PROCEDURE ToInteger (n: SYSTEM.INT32): INTEGER;
(* n as an INTEGER.  INT32 is narrower than LONGINT under -O2 and as wide
   under -OC, and SHORT(LONGINT) is INTEGER under both. *)
  VAR wide: LONGINT;
BEGIN
  wide := n;
  RETURN SHORT(wide)
END ToInteger;

PROCEDURE ToInt32 (n: LONGINT): SYSTEM.INT32;
(* n, which fits, as an INT32.  SHORT(HUGEINT) is LONGINT under -O2 and
   INTEGER under -OC, 32 bits under both. *)
  VAR wide: HUGEINT;
BEGIN
  wide := n;
  RETURN SHORT(wide)
END ToInt32;

PROCEDURE OnlySpace (VAR sql: ARRAY OF CHAR; i: SYSTEM.ADDRESS): BOOLEAN;
(* TRUE if sql from i on holds nothing but blanks, semicolons and comments.
   i is an ADDRESS because it is the difference of two addresses. *)
BEGIN
  LOOP
    IF (i >= LEN(sql)) OR (sql[i] = 0X) THEN RETURN TRUE
    ELSIF (sql[i] <= " ") OR (sql[i] = ";") THEN INC(i)
    ELSIF (sql[i] = "-") & (i + 1 < LEN(sql)) & (sql[i + 1] = "-") THEN
      WHILE (i < LEN(sql)) & (sql[i] # 0X) & (sql[i] # 0AX) DO INC(i) END
    ELSIF (sql[i] = "/") & (i + 1 < LEN(sql)) & (sql[i + 1] = "*") THEN
      INC(i, 2);
      WHILE (i + 1 < LEN(sql)) & (sql[i] # 0X) & ~((sql[i] = "*") & (sql[i + 1] = "/")) DO
        INC(i)
      END;
      INC(i, 2)
    ELSE RETURN FALSE
    END
  END
END OnlySpace;


(* ---- Driver ---- *)

PROCEDURE (d: Driver) Open* (url: ARRAY OF CHAR): Db.Connection;
(* Open or create the database that url names; see the module's comment. *)
  VAR c: Connection; path: Text; i, k: LONGINT; result: SYSTEM.INT32;
BEGIN
  i := 0;
  WHILE url[i] # ":" DO INC(i) END;   (* Db.Open found the colon *)
  INC(i);
  IF (url[i] = "/") & (i + 1 < LEN(url)) & (url[i + 1] = "/") THEN
    INC(i, 2);
    IF url[i] # "/" THEN
      Db.lastError := "DbSqlite: a sqlite: URL takes no host; use sqlite:///path for an absolute path";
      RETURN NIL
    END;
    IF url[i + 1] = ":" THEN INC(i) END   (* sqlite:///:memory: *)
  END;
  IF (i >= LEN(url)) OR (url[i] = 0X) THEN
    Db.lastError := "DbSqlite: the URL names no database file";
    RETURN NIL
  END;
  NEW(path, LEN(url));
  k := 0;
  WHILE (i < LEN(url)) & (url[i] # 0X) DO path[k] := url[i]; INC(k); INC(i) END;
  path[k] := 0X;

  NEW(c); c.err := Db.noError; c.msg[0] := 0X; c.db := 0;
  result := OpenDatabase(SYSTEM.ADR(path[0]), SYSTEM.ADR(c.db), openReadWrite + openCreate, 0);
  IF result # sqliteOk THEN
    IF c.db = 0 THEN Db.lastError := "DbSqlite: out of memory"
    ELSE DbCStrings.Copy(ErrorMessage(c.db), Db.lastError); result := CloseDatabase(c.db)
    END;
    RETURN NIL
  END;
  RETURN c
END Open;


(* ---- Connection ---- *)

PROCEDURE (c: Connection) Close* ;
(* Close the connection.  Statements still open keep the database open
   until they are finalized.  It leaves c.err as it is. *)
  VAR result: SYSTEM.INT32;
BEGIN
  IF c.db # 0 THEN result := CloseDatabase(c.db); c.db := 0 END
END Close;

PROCEDURE (c: Connection) Prepare* (sql: ARRAY OF CHAR; VAR s: Db.Statement): BOOLEAN;
(* Translate sql's placeholders to ?1, ?2 ... and prepare it. *)
  VAR st: Statement; translated: Text; tail: SYSTEM.ADDRESS; result: SYSTEM.INT32;
BEGIN
  c.err := Db.noError;
  s := NIL;
  IF c.db = 0 THEN Db.SetError(c, Db.errSql, "DbSqlite: the connection is closed"); RETURN FALSE END;
  NEW(st);
  (* ":a" can become "?10", and each of at most 64 "?"s "?64" *)
  NEW(translated, LEN(sql) + LEN(sql) DIV 2 + 130);
  IF ~Db.Translate(sql, "?", translated^, st.params) THEN
    Db.SetError(c, Db.errSql,
      "DbSqlite: placeholders mix ? and :name, number over 64, or have a name over 31 characters");
    RETURN FALSE
  END;
  result := PrepareStatement(c.db, SYSTEM.ADR(translated[0]), -1, SYSTEM.ADR(st.stmt), SYSTEM.ADR(tail));
  IF result # sqliteOk THEN SetSqliteError(c, Db.errSql, c.db); RETURN FALSE END;
  IF st.stmt = 0 THEN Db.SetError(c, Db.errSql, "DbSqlite: no SQL statement"); RETURN FALSE END;
  IF ~OnlySpace(translated^, tail - SYSTEM.ADR(translated[0])) THEN
    result := FinalizeStatement(st.stmt);
    Db.SetError(c, Db.errSql, "DbSqlite: more than one SQL statement");
    RETURN FALSE
  END;
  IF ParameterCount(st.stmt) # st.params.n THEN
    result := FinalizeStatement(st.stmt);
    Db.SetError(c, Db.errSql, "DbSqlite: the statement has placeholders that Db does not translate");
    RETURN FALSE
  END;
  st.conn := c; st.db := c.db; st.onRow := FALSE; st.before := 0; st.changes := 0;
  s := st;
  RETURN TRUE
END Prepare;


(* ---- Statement: binding ---- *)

PROCEDURE Live (s: Statement): BOOLEAN;
(* Clear s.conn's error; FALSE, with an error, if s is finalized. *)
BEGIN
  s.conn.err := Db.noError;
  IF s.stmt = 0 THEN Db.SetError(s.conn, Db.errSql, "DbSqlite: the statement is finalized") END;
  RETURN s.stmt # 0
END Live;

PROCEDURE CheckBind (s: Statement; result: SYSTEM.INT32);
(* Report a bind that SQLite refused. *)
BEGIN
  IF result = sqliteRange THEN SetSqliteError(s.conn, Db.errRange, s.db)
  ELSIF result # sqliteOk THEN SetSqliteError(s.conn, Db.errSql, s.db)
  END
END CheckBind;

PROCEDURE (s: Statement) BindNull* (i: INTEGER);
(* Bind NULL to parameter i (1-based). *)
BEGIN
  IF Live(s) THEN CheckBind(s, BindNullValue(s.stmt, i)) END
END BindNull;

PROCEDURE (s: Statement) BindInt* (i: INTEGER; v: HUGEINT);
(* Bind the integer v to parameter i (1-based). *)
BEGIN
  IF Live(s) THEN CheckBind(s, BindInt64(s.stmt, i, v)) END
END BindInt;

PROCEDURE (s: Statement) BindReal* (i: INTEGER; v: LONGREAL);
(* Bind the real number v to parameter i (1-based). *)
BEGIN
  IF Live(s) THEN CheckBind(s, BindDouble(s.stmt, i, v)) END
END BindReal;

PROCEDURE (s: Statement) BindText* (i: INTEGER; v: ARRAY OF CHAR);
(* Bind the text v, up to its 0X, to parameter i (1-based).  SQLite copies
   it, since v lives only as long as this call. *)
  VAR n: SYSTEM.INT32;
BEGIN
  IF Live(s) THEN
    n := 0;
    WHILE (n < LEN(v)) & (v[n] # 0X) DO INC(n) END;
    CheckBind(s, BindTextValue(s.stmt, i, SYSTEM.ADR(v[0]), n, transient))
  END
END BindText;


PROCEDURE (s: Statement) BindBlob* (i: INTEGER; VAR v: ARRAY OF CHAR; n: LONGINT);
(* Bind v[0] .. v[n-1] as a BLOB to parameter i (1-based).  SQLite copies
   it. *)
BEGIN
  IF Live(s) THEN
    IF (n < 0) OR (n > LEN(v)) OR (n > MAX(SYSTEM.INT32)) THEN
      Db.SetError(s.conn, Db.errRange, "DbSqlite: BindBlob's length is outside the array")
    ELSIF n = 0 THEN CheckBind(s, BindZeroBlob(s.stmt, i, 0))
    ELSE CheckBind(s, BindBlobValue(s.stmt, i, SYSTEM.ADR(v[0]), ToInt32(n), transient))
    END
  END
END BindBlob;


(* ---- Statement: stepping ---- *)

PROCEDURE (s: Statement) Step* (): BOOLEAN;
(* Advance to the next row: TRUE if there is one, FALSE when the statement
   is done or has failed (then s.conn.err says which). *)
  VAR result: SYSTEM.INT32;
BEGIN
  s.onRow := FALSE;
  IF Live(s) THEN
    IF StatementBusy(s.stmt) = 0 THEN   (* a new run *)
      s.before := TotalChanges(s.db); s.changes := 0
    END;
    result := StepStatement(s.stmt);
    IF result = sqliteRow THEN s.onRow := TRUE
    ELSIF result = sqliteDone THEN
      (* sqlite3_changes64 is the last INSERT, UPDATE or DELETE's count,
         which may be another statement's if this one changed nothing *)
      IF TotalChanges(s.db) # s.before THEN s.changes := ChangesOf(s.db) END
    ELSE SetSqliteError(s.conn, Db.errSql, s.db)
    END
  END;
  RETURN s.onRow
END Step;

PROCEDURE (s: Statement) Reset* ;
(* Rewind the statement and clear its parameters, so it can be bound and
   stepped again. *)
  VAR result: SYSTEM.INT32;
BEGIN
  s.onRow := FALSE; s.changes := 0;
  IF Live(s) THEN
    result := ResetStatement(s.stmt);   (* repeats the last Step's error, already reported *)
    result := ClearBindings(s.stmt)
  END
END Reset;

PROCEDURE (s: Statement) Finalize* ;
(* Free the statement.  Finalizing it again does nothing.  It leaves
   s.conn.err as it is, so a failed Step is still reported after it. *)
  VAR result: SYSTEM.INT32;
BEGIN
  s.onRow := FALSE;
  IF s.stmt # 0 THEN result := FinalizeStatement(s.stmt); s.stmt := 0 END
END Finalize;


PROCEDURE (s: Statement) Changes* (): HUGEINT;
(* The rows the statement's last run inserted, updated or deleted, once Step
   has returned FALSE. *)
BEGIN
  RETURN s.changes
END Changes;


(* ---- Statement: reading columns ---- *)

PROCEDURE OnColumn (s: Statement; i: INTEGER): BOOLEAN;
(* Clear s.conn's error; FALSE, with errRange, unless s is on a row that has
   a column i. *)
BEGIN
  IF ~Live(s) THEN RETURN FALSE
  ELSIF ~s.onRow THEN Db.SetError(s.conn, Db.errRange, "DbSqlite: no current row"); RETURN FALSE
  ELSIF (i < 0) OR (i >= ColumnCountOf(s.stmt)) THEN
    Db.SetError(s.conn, Db.errRange, "DbSqlite: no such column"); RETURN FALSE
  END;
  RETURN TRUE
END OnColumn;

PROCEDURE (s: Statement) ColumnCount* (): INTEGER;
(* Number of columns in the statement's result. *)
BEGIN
  IF ~Live(s) THEN RETURN 0 END;
  RETURN ToInteger(ColumnCountOf(s.stmt))
END ColumnCount;

PROCEDURE (s: Statement) ColumnName* (i: INTEGER; VAR out: ARRAY OF CHAR);
(* Name of result column i (0-based), truncated to fit out. *)
BEGIN
  out[0] := 0X;
  IF Live(s) THEN
    IF (i >= 0) & (i < ColumnCountOf(s.stmt)) THEN DbCStrings.Copy(ColumnNameOf(s.stmt, i), out)
    ELSE Db.SetError(s.conn, Db.errRange, "DbSqlite: no such column")
    END
  END
END ColumnName;

PROCEDURE (s: Statement) ColumnType* (i: INTEGER): INTEGER;
(* Type of column i's value in the current row: Db.typeNull, typeInt,
   typeReal, typeText or typeBlob. *)
  VAR type: SYSTEM.INT32;
BEGIN
  IF ~OnColumn(s, i) THEN RETURN Db.typeNull END;
  type := ColumnTypeOf(s.stmt, i);
  IF type = integerColumn THEN RETURN Db.typeInt
  ELSIF type = floatColumn THEN RETURN Db.typeReal
  ELSIF type = textColumn THEN RETURN Db.typeText
  ELSIF type = blobColumn THEN RETURN Db.typeBlob
  ELSE RETURN Db.typeNull
  END
END ColumnType;

PROCEDURE (s: Statement) ColumnInt* (i: INTEGER): HUGEINT;
(* Column i's value as an integer, converted by SQLite; 0 for NULL. *)
BEGIN
  IF ~OnColumn(s, i) THEN RETURN 0 END;
  RETURN ColumnInt64(s.stmt, i)
END ColumnInt;

PROCEDURE (s: Statement) ColumnReal* (i: INTEGER): LONGREAL;
(* Column i's value as a real number, converted by SQLite; 0 for NULL. *)
BEGIN
  IF ~OnColumn(s, i) THEN RETURN 0 END;
  RETURN ColumnDouble(s.stmt, i)
END ColumnReal;

PROCEDURE (s: Statement) ColumnText* (i: INTEGER; VAR out: ARRAY OF CHAR);
(* Column i's value as text, truncated to fit out; "" for NULL. *)
BEGIN
  out[0] := 0X;
  IF OnColumn(s, i) THEN DbCStrings.Copy(ColumnTextOf(s.stmt, i), out) END
END ColumnText;

PROCEDURE (s: Statement) ColumnBlob* (i: INTEGER; VAR out: ARRAY OF CHAR): LONGINT;
(* Copy as many of column i's bytes as fit into out and return its whole
   length; 0 for NULL.  A number gives the bytes of its text form. *)
  VAR p: SYSTEM.ADDRESS; length, n: LONGINT;
BEGIN
  IF ~OnColumn(s, i) THEN RETURN 0 END;
  p := ColumnBlobOf(s.stmt, i);   (* before sqlite3_column_bytes, which this may convert *)
  length := ColumnBytes(s.stmt, i);
  n := length;
  IF n > LEN(out) THEN n := LEN(out) END;
  IF (n > 0) & (p # 0) THEN SYSTEM.MOVE(p, SYSTEM.ADR(out[0]), n) END;
  RETURN length
END ColumnBlob;


BEGIN
  NEW(driver);
  Db.Register(driver, "sqlite")
END DbSqlite.
