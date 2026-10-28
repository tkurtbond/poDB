MODULE DbPostgres;
(* The PostgreSQL driver for Db, on libpq.  Importing this module registers
   it under the schemes "postgres" and "postgresql".  Db.Open hands the
   whole URL to libpq, so it takes any connection URI libpq does:

     postgres://user:password@host:5432/dbname
     postgres:///dbname?host=/path/to/socket/directory&user=name

   Each Prepare makes a server-side prepared statement named podb_1,
   podb_2 ... (unique on its connection), and Finalize deallocates it
   (decision D5).  Parameters and results travel as text (decision D6): the
   numeric binders format the value, and ColumnInt and ColumnReal parse the
   column's text.  ColumnType gives typeInt for int2, int4 and int8,
   typeReal for float4, float8 and numeric, and typeText for every other
   type, bool included.  The server's notices are not printed. *)

IMPORT SYSTEM, Db, DbCStrings;

CONST
  (* libpq-fe.h *)
  connectionOk = 0;
  emptyQuery = 0;
  commandOk = 1;
  tuplesOk = 2;
  (* pg_type.h *)
  int8Oid = 20;
  int2Oid = 21;
  int4Oid = 23;
  float4Oid = 700;
  float8Oid = 701;
  numericOid = 1700;

  maxStatementName = 32;
  numberSize = 32;   (* holds a HUGEINT, or a LONGREAL to 17 digits *)

TYPE
  Text = POINTER TO ARRAY OF CHAR;
  Values = POINTER TO ARRAY OF Text;
  Addresses = POINTER TO ARRAY OF SYSTEM.ADDRESS;
  StatementName = ARRAY maxStatementName OF CHAR;

  Connection = POINTER TO ConnectionDesc;
  ConnectionDesc = RECORD (Db.ConnectionDesc)
    pg: SYSTEM.ADDRESS;   (* PGconn *, or 0 once closed *)
    prepared: LONGINT     (* the number of statements prepared, for their names *)
  END;

  Statement = POINTER TO StatementDesc;
  StatementDesc = RECORD (Db.StatementDesc)
    name: StatementName;        (* the prepared statement's name on the server *)
    description: SYSTEM.ADDRESS;   (* PGresult * from PQdescribePrepared, or 0 once finalized *)
    result: SYSTEM.ADDRESS;     (* PGresult * from PQexecPrepared, or 0 *)
    executed: BOOLEAN;          (* Step has run the statement since Prepare or Reset *)
    row, rows: SYSTEM.INT32;    (* the current row (-1 before the first) and the number of rows *)
    value: Values;              (* value[i] is parameter i+1 as text; NIL is NULL *)
    address: Addresses          (* the addresses of value's texts, for libpq *)
  END;

  Driver = POINTER TO DriverDesc;
  DriverDesc = RECORD (Db.DriverDesc) END;

VAR
  driver, alias: Driver;


(* ---- libpq ---- *)

PROCEDURE ["C", "PQconnectdb"] ConnectDatabase (conninfo: SYSTEM.ADDRESS): SYSTEM.ADDRESS;
PROCEDURE ["C", "PQstatus"] ConnectionStatus (conn: SYSTEM.ADDRESS): SYSTEM.INT32;
PROCEDURE ["C", "PQerrorMessage"] ConnectionError (conn: SYSTEM.ADDRESS): SYSTEM.ADDRESS;
PROCEDURE ["C", "PQfinish"] Finish (conn: SYSTEM.ADDRESS);
PROCEDURE ["C", "PQprepare"] PrepareStatement (conn, name, query: SYSTEM.ADDRESS;
    nParams: SYSTEM.INT32; paramTypes: SYSTEM.ADDRESS): SYSTEM.ADDRESS;
PROCEDURE ["C", "PQdescribePrepared"] DescribePrepared (conn, name: SYSTEM.ADDRESS): SYSTEM.ADDRESS;
PROCEDURE ["C", "PQexecPrepared"] ExecutePrepared (conn, name: SYSTEM.ADDRESS;
    nParams: SYSTEM.INT32; paramValues, paramLengths, paramFormats: SYSTEM.ADDRESS;
    resultFormat: SYSTEM.INT32): SYSTEM.ADDRESS;
PROCEDURE ["C", "PQclosePrepared"] ClosePrepared (conn, name: SYSTEM.ADDRESS): SYSTEM.ADDRESS;
PROCEDURE ["C", "PQresultStatus"] ResultStatus (result: SYSTEM.ADDRESS): SYSTEM.INT32;
PROCEDURE ["C", "PQresultErrorMessage"] ResultError (result: SYSTEM.ADDRESS): SYSTEM.ADDRESS;
PROCEDURE ["C", "PQclear"] Clear (result: SYSTEM.ADDRESS);
PROCEDURE ["C", "PQnparams"] ParameterCount (result: SYSTEM.ADDRESS): SYSTEM.INT32;
PROCEDURE ["C", "PQntuples"] RowCount (result: SYSTEM.ADDRESS): SYSTEM.INT32;
PROCEDURE ["C", "PQnfields"] FieldCount (result: SYSTEM.ADDRESS): SYSTEM.INT32;
PROCEDURE ["C", "PQfname"] FieldName (result: SYSTEM.ADDRESS; i: SYSTEM.INT32): SYSTEM.ADDRESS;
PROCEDURE ["C", "PQftype"] FieldType (result: SYSTEM.ADDRESS; i: SYSTEM.INT32): SYSTEM.CARD32;
PROCEDURE ["C", "PQgetvalue"] GetValue (result: SYSTEM.ADDRESS; row, i: SYSTEM.INT32): SYSTEM.ADDRESS;
PROCEDURE ["C", "PQgetisnull"] GetIsNull (result: SYSTEM.ADDRESS; row, i: SYSTEM.INT32): SYSTEM.INT32;

(* DbPostgres.c *)
PROCEDURE ["C", "podb_format_int"] FormatInt (v: SYSTEM.INT64; out, size: SYSTEM.ADDRESS);
PROCEDURE ["C", "podb_format_real"] FormatReal (v: LONGREAL; out, size: SYSTEM.ADDRESS);
PROCEDURE ["C", "podb_parse_int"] ParseInt (s, v: SYSTEM.ADDRESS): SYSTEM.INT32;
PROCEDURE ["C", "podb_parse_real"] ParseReal (s, v: SYSTEM.ADDRESS): SYSTEM.INT32;
PROCEDURE ["C", "podb_ignore_notices"] IgnoreNotices (conn: SYSTEM.ADDRESS);


(* ---- Helpers ---- *)

PROCEDURE CopyMessage (p: SYSTEM.ADDRESS; VAR out: ARRAY OF CHAR);
(* Copy libpq's message p into out, without the line ends at its end. *)
  VAR i: LONGINT;
BEGIN
  DbCStrings.Copy(p, out);
  i := 0;
  WHILE out[i] # 0X DO INC(i) END;
  WHILE (i > 0) & (out[i - 1] <= " ") DO DEC(i); out[i] := 0X END
END CopyMessage;

PROCEDURE SetResultError (c: Connection; result: SYSTEM.ADDRESS);
(* Set c's error to errSql, with the message for result, or the
   connection's message if there is no result. *)
  VAR msg: Db.Message;
BEGIN
  IF result = 0 THEN CopyMessage(ConnectionError(c.pg), msg)
  ELSE CopyMessage(ResultError(result), msg)
  END;
  Db.SetError(c, Db.errSql, msg)
END SetResultError;

PROCEDURE ToInteger (n: SYSTEM.INT32): INTEGER;
(* n as an INTEGER.  INT32 is narrower than LONGINT under -O2 and as wide
   under -OC, and SHORT(LONGINT) is INTEGER under both. *)
  VAR wide: LONGINT;
BEGIN
  wide := n;
  RETURN SHORT(wide)
END ToInteger;

PROCEDURE MakeName (n: LONGINT; VAR name: StatementName);
(* name := "podb_" followed by n in decimal; n > 0 *)
  VAR digits: ARRAY 24 OF CHAR; k, i: LONGINT;
BEGIN
  k := 0;
  REPEAT digits[k] := CHR(ORD("0") + n MOD 10); n := n DIV 10; INC(k) UNTIL n = 0;
  name := "podb_"; i := 5;
  WHILE k > 0 DO DEC(k); name[i] := digits[k]; INC(i) END;
  name[i] := 0X
END MakeName;

PROCEDURE Deallocate (c: Connection; name: StatementName);
(* Drop the prepared statement name on c's server.  PQclosePrepared does
   what DEALLOCATE does, but as a protocol message rather than an SQL
   command, so it works in a transaction that has already failed, where
   the server refuses every command but ROLLBACK. *)
BEGIN
  IF c.pg # 0 THEN Clear(ClosePrepared(c.pg, SYSTEM.ADR(name))) END
END Deallocate;


(* ---- Driver ---- *)

PROCEDURE (d: Driver) Open* (url: ARRAY OF CHAR): Db.Connection;
(* Connect to the database that url names; see the module's comment. *)
  VAR c: Connection;
BEGIN
  NEW(c); c.err := Db.noError; c.msg[0] := 0X; c.prepared := 0;
  c.pg := ConnectDatabase(SYSTEM.ADR(url));
  IF c.pg = 0 THEN Db.lastError := "DbPostgres: out of memory"; RETURN NIL END;
  IF ConnectionStatus(c.pg) # connectionOk THEN
    CopyMessage(ConnectionError(c.pg), Db.lastError);
    Finish(c.pg);
    RETURN NIL
  END;
  IgnoreNotices(c.pg);
  RETURN c
END Open;


(* ---- Connection ---- *)

PROCEDURE (c: Connection) Close* ;
(* Close the connection.  Its statements can then only be finalized.  It
   leaves c.err as it is. *)
BEGIN
  IF c.pg # 0 THEN Finish(c.pg); c.pg := 0 END
END Close;

PROCEDURE (c: Connection) Prepare* (sql: ARRAY OF CHAR; VAR s: Db.Statement): BOOLEAN;
(* Translate sql's placeholders to $1, $2 ... and prepare it on the server. *)
  VAR st: Statement; translated: Text; result: SYSTEM.ADDRESS; n: INTEGER;
BEGIN
  c.err := Db.noError;
  s := NIL;
  IF c.pg = 0 THEN Db.SetError(c, Db.errSql, "DbPostgres: the connection is closed"); RETURN FALSE END;
  NEW(st);
  (* ":a" can become "$10", and each of at most 64 "?"s "$64" *)
  NEW(translated, LEN(sql) + LEN(sql) DIV 2 + 130);
  IF ~Db.Translate(sql, "$", translated^, st.params) THEN
    Db.SetError(c, Db.errSql,
      "DbPostgres: placeholders mix ? and :name, number over 64, or have a name over 31 characters");
    RETURN FALSE
  END;
  INC(c.prepared);
  MakeName(c.prepared, st.name);
  result := PrepareStatement(c.pg, SYSTEM.ADR(st.name), SYSTEM.ADR(translated[0]), st.params.n, 0);
  IF ResultStatus(result) # commandOk THEN
    SetResultError(c, result); Clear(result); RETURN FALSE
  END;
  Clear(result);
  st.description := DescribePrepared(c.pg, SYSTEM.ADR(st.name));
  IF ResultStatus(st.description) # commandOk THEN
    SetResultError(c, st.description); Clear(st.description);
    Deallocate(c, st.name); RETURN FALSE
  END;
  IF ParameterCount(st.description) # st.params.n THEN
    Clear(st.description); Deallocate(c, st.name);
    Db.SetError(c, Db.errSql, "DbPostgres: the statement has placeholders that Db does not translate");
    RETURN FALSE
  END;
  n := st.params.n;
  IF n = 0 THEN n := 1 END;   (* so that address[0] exists *)
  NEW(st.value, n); NEW(st.address, n);
  st.result := 0; st.executed := FALSE; st.row := -1; st.rows := 0;
  st.conn := c;
  s := st;
  RETURN TRUE
END Prepare;


(* ---- Statement: binding ---- *)

PROCEDURE Live (s: Statement): BOOLEAN;
(* Clear s.conn's error; FALSE, with an error, if s is finalized or its
   connection closed. *)
BEGIN
  s.conn.err := Db.noError;
  IF s.description = 0 THEN
    Db.SetError(s.conn, Db.errSql, "DbPostgres: the statement is finalized"); RETURN FALSE
  ELSIF s.conn(Connection).pg = 0 THEN
    Db.SetError(s.conn, Db.errSql, "DbPostgres: the connection is closed"); RETURN FALSE
  END;
  RETURN TRUE
END Live;

PROCEDURE SetValue (s: Statement; i: INTEGER; v: Text);
(* Make v, as text or NIL for NULL, the value of parameter i (1-based). *)
BEGIN
  IF Live(s) THEN
    IF (i < 1) OR (i > s.params.n) THEN
      Db.SetError(s.conn, Db.errRange, "DbPostgres: no such parameter")
    ELSE
      s.value[i - 1] := v
    END
  END
END SetValue;

PROCEDURE (s: Statement) BindNull* (i: INTEGER);
(* Bind NULL to parameter i (1-based). *)
BEGIN
  SetValue(s, i, NIL)
END BindNull;

PROCEDURE (s: Statement) BindInt* (i: INTEGER; v: HUGEINT);
(* Bind the integer v to parameter i (1-based), as text. *)
  VAR t: Text;
BEGIN
  NEW(t, numberSize); FormatInt(v, SYSTEM.ADR(t[0]), numberSize);
  SetValue(s, i, t)
END BindInt;

PROCEDURE (s: Statement) BindReal* (i: INTEGER; v: LONGREAL);
(* Bind the real number v to parameter i (1-based), as text with enough
   digits to give v back exactly. *)
  VAR t: Text;
BEGIN
  NEW(t, numberSize); FormatReal(v, SYSTEM.ADR(t[0]), numberSize);
  SetValue(s, i, t)
END BindReal;

PROCEDURE (s: Statement) BindText* (i: INTEGER; v: ARRAY OF CHAR);
(* Bind the text v, up to its 0X, to parameter i (1-based).  The statement
   keeps a copy, since v lives only as long as this call. *)
  VAR t: Text; n, k: LONGINT;
BEGIN
  n := 0;
  WHILE (n < LEN(v)) & (v[n] # 0X) DO INC(n) END;
  NEW(t, n + 1);
  FOR k := 0 TO n - 1 DO t[k] := v[k] END;
  t[n] := 0X;
  SetValue(s, i, t)
END BindText;


(* ---- Statement: stepping ---- *)

PROCEDURE Run (s: Statement);
(* Execute s with its current parameters and keep the result. *)
  VAR c: Connection; i: INTEGER; status: SYSTEM.INT32;
BEGIN
  c := s.conn(Connection);
  FOR i := 0 TO s.params.n - 1 DO
    IF s.value[i] = NIL THEN s.address[i] := 0 ELSE s.address[i] := SYSTEM.ADR(s.value[i][0]) END
  END;
  s.result := ExecutePrepared(c.pg, SYSTEM.ADR(s.name), s.params.n, SYSTEM.ADR(s.address[0]), 0, 0, 0);
  s.executed := TRUE; s.row := -1; s.rows := 0;
  status := ResultStatus(s.result);
  IF status = tuplesOk THEN s.rows := RowCount(s.result)
  ELSIF status = emptyQuery THEN Db.SetError(c, Db.errSql, "DbPostgres: no SQL statement")
  ELSIF status # commandOk THEN SetResultError(c, s.result)
  END
END Run;

PROCEDURE (s: Statement) Step* (): BOOLEAN;
(* Advance to the next row: TRUE if there is one, FALSE when the statement
   is done or has failed (then s.conn.err says which).  The first Step after
   Prepare or Reset executes the statement and fetches all its rows. *)
BEGIN
  IF ~Live(s) THEN RETURN FALSE END;
  IF ~s.executed THEN Run(s) END;
  IF s.row < s.rows THEN INC(s.row) END;
  RETURN s.row < s.rows
END Step;

PROCEDURE (s: Statement) Reset* ;
(* Rewind the statement so it can be stepped again.  Its parameters keep
   their values until they are bound again. *)
BEGIN
  IF Live(s) THEN
    Clear(s.result); s.result := 0;
    s.executed := FALSE; s.row := -1; s.rows := 0
  END
END Reset;

PROCEDURE (s: Statement) Finalize* ;
(* Free the statement and deallocate it on the server.  Finalizing it again
   does nothing.  It leaves s.conn.err as it is, so a failed Step is still
   reported after it. *)
BEGIN
  IF s.description # 0 THEN
    Clear(s.result); s.result := 0;
    Clear(s.description); s.description := 0;
    s.executed := FALSE; s.row := -1; s.rows := 0;
    s.value := NIL; s.address := NIL;
    Deallocate(s.conn(Connection), s.name)
  END
END Finalize;


(* ---- Statement: reading columns ---- *)

PROCEDURE OnColumn (s: Statement; i: INTEGER): BOOLEAN;
(* Clear s.conn's error; FALSE, with errRange, unless s is on a row that has
   a column i. *)
BEGIN
  IF ~Live(s) THEN RETURN FALSE
  ELSIF (s.result = 0) OR (s.row < 0) OR (s.row >= s.rows) THEN
    Db.SetError(s.conn, Db.errRange, "DbPostgres: no current row"); RETURN FALSE
  ELSIF (i < 0) OR (i >= FieldCount(s.result)) THEN
    Db.SetError(s.conn, Db.errRange, "DbPostgres: no such column"); RETURN FALSE
  END;
  RETURN TRUE
END OnColumn;

PROCEDURE IsNull (s: Statement; i: INTEGER): BOOLEAN;
(* TRUE if column i of the current row is NULL; s is on a row with column i. *)
BEGIN
  RETURN GetIsNull(s.result, s.row, i) # 0
END IsNull;

PROCEDURE (s: Statement) ColumnCount* (): INTEGER;
(* Number of columns in the statement's result; known before the first Step. *)
BEGIN
  IF ~Live(s) THEN RETURN 0 END;
  RETURN ToInteger(FieldCount(s.description))
END ColumnCount;

PROCEDURE (s: Statement) ColumnName* (i: INTEGER; VAR out: ARRAY OF CHAR);
(* Name of result column i (0-based), truncated to fit out. *)
BEGIN
  out[0] := 0X;
  IF Live(s) THEN
    IF (i >= 0) & (i < FieldCount(s.description)) THEN DbCStrings.Copy(FieldName(s.description, i), out)
    ELSE Db.SetError(s.conn, Db.errRange, "DbPostgres: no such column")
    END
  END
END ColumnName;

PROCEDURE (s: Statement) ColumnType* (i: INTEGER): INTEGER;
(* Type of column i's value in the current row: Db.typeNull, typeInt,
   typeReal or typeText. *)
  VAR type: SYSTEM.CARD32;
BEGIN
  IF ~OnColumn(s, i) OR IsNull(s, i) THEN RETURN Db.typeNull END;
  type := FieldType(s.result, i);
  IF (type = int2Oid) OR (type = int4Oid) OR (type = int8Oid) THEN RETURN Db.typeInt
  ELSIF (type = float4Oid) OR (type = float8Oid) OR (type = numericOid) THEN RETURN Db.typeReal
  ELSE RETURN Db.typeText
  END
END ColumnType;

PROCEDURE (s: Statement) ColumnInt* (i: INTEGER): HUGEINT;
(* Column i's value as an integer; 0 for NULL.  A real number is truncated
   toward zero.  Text that is not a number gives 0 and errRange. *)
  VAR v: HUGEINT;
BEGIN
  v := 0;
  IF OnColumn(s, i) & ~IsNull(s, i) THEN
    IF ParseInt(GetValue(s.result, s.row, i), SYSTEM.ADR(v)) = 0 THEN
      Db.SetError(s.conn, Db.errRange, "DbPostgres: the value is not an integer")
    END
  END;
  RETURN v
END ColumnInt;

PROCEDURE (s: Statement) ColumnReal* (i: INTEGER): LONGREAL;
(* Column i's value as a real number; 0 for NULL.  Text that is not a
   number gives 0 and errRange. *)
  VAR v: LONGREAL;
BEGIN
  v := 0;
  IF OnColumn(s, i) & ~IsNull(s, i) THEN
    IF ParseReal(GetValue(s.result, s.row, i), SYSTEM.ADR(v)) = 0 THEN
      Db.SetError(s.conn, Db.errRange, "DbPostgres: the value is not a number")
    END
  END;
  RETURN v
END ColumnReal;

PROCEDURE (s: Statement) ColumnText* (i: INTEGER; VAR out: ARRAY OF CHAR);
(* Column i's value as text, truncated to fit out; "" for NULL. *)
BEGIN
  out[0] := 0X;
  IF OnColumn(s, i) THEN DbCStrings.Copy(GetValue(s.result, s.row, i), out) END
END ColumnText;


BEGIN
  NEW(driver);
  Db.Register(driver, "postgres");
  NEW(alias);
  Db.Register(alias, "postgresql")
END DbPostgres.
