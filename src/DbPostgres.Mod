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
   column's text.  The one exception is BindBlob, which sends its bytes in
   binary format, for a bytea parameter; ColumnBlob unescapes a bytea
   column's text.  ColumnType gives typeInt for int2, int4 and int8,
   typeReal for float4, float8 and numeric, typeBlob for bytea, and
   typeText for every other type, bool included.  The server's notices are
   not printed.

   A query's rows arrive in chunks of chunkRows (libpq's chunked rows
   mode), so Step holds one chunk at a time, not the whole result.  While
   a statement's rows are arriving, its connection can run nothing else.
   So before another command goes to the server, Drain reads the rest of
   that statement's results and queues them in the statement, which then
   steps through them from memory. *)

IMPORT SYSTEM, Db, DbCStrings;

CONST
  (* libpq-fe.h *)
  connectionOk = 0;
  emptyQuery = 0;
  commandOk = 1;
  tuplesOk = 2;
  tuplesChunk = 12;
  textFormat = 0;
  binaryFormat = 1;
  (* pg_type.h *)
  byteaOid = 17;
  int8Oid = 20;
  int2Oid = 21;
  int4Oid = 23;
  float4Oid = 700;
  float8Oid = 701;
  numericOid = 1700;

  maxStatementName = 32;
  numberSize = 32;   (* holds a HUGEINT, or a LONGREAL to 17 digits *)
  chunkRows = 100;   (* the rows in each chunk of a result *)

TYPE
  Text = POINTER TO ARRAY OF CHAR;
  Values = POINTER TO ARRAY OF Text;
  Addresses = POINTER TO ARRAY OF SYSTEM.ADDRESS;
  Int32s = POINTER TO ARRAY OF SYSTEM.INT32;
  StatementName = ARRAY maxStatementName OF CHAR;

  Statement = POINTER TO StatementDesc;

  Connection = POINTER TO ConnectionDesc;
  ConnectionDesc = RECORD (Db.ConnectionDesc)
    pg: SYSTEM.ADDRESS;   (* PGconn *, or 0 once closed *)
    prepared: LONGINT;    (* the number of statements prepared, for their names *)
    active: Statement     (* the statement whose results are still arriving, or NIL *)
  END;

  Pending = POINTER TO PendingDesc;
  PendingDesc = RECORD
    result: SYSTEM.ADDRESS;   (* a PGresult * that Drain read for a statement *)
    next: Pending
  END;

  StatementDesc = RECORD (Db.StatementDesc)
    name: StatementName;        (* the prepared statement's name on the server *)
    description: SYSTEM.ADDRESS;   (* PGresult * from PQdescribePrepared, or 0 once finalized *)
    result: SYSTEM.ADDRESS;     (* the PGresult * Step is reading rows from, or 0 *)
    first, last: Pending;       (* the results Drain queued, oldest first *)
    executed: BOOLEAN;          (* Step has run the statement since Prepare or Reset *)
    done: BOOLEAN;              (* the run's last result has been read *)
    row, rows: SYSTEM.INT32;    (* the current row in result (-1 before the first) and result's rows *)
    changes: HUGEINT;           (* the rows the last run changed *)
    value: Values;              (* value[i] is parameter i+1 as text; NIL is NULL *)
    address: Addresses;         (* the addresses of value's texts, for libpq *)
    length: Int32s;             (* length[i] is value[i]'s length in bytes, if it is binary *)
    format: Int32s              (* format[i] is textFormat or binaryFormat *)
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
PROCEDURE ["C", "PQsendQueryPrepared"] SendPrepared (conn, name: SYSTEM.ADDRESS;
    nParams: SYSTEM.INT32; paramValues, paramLengths, paramFormats: SYSTEM.ADDRESS;
    resultFormat: SYSTEM.INT32): SYSTEM.INT32;
PROCEDURE ["C", "PQsetChunkedRowsMode"] SetChunkedRows (conn: SYSTEM.ADDRESS; chunkSize: SYSTEM.INT32): SYSTEM.INT32;
PROCEDURE ["C", "PQgetResult"] GetResult (conn: SYSTEM.ADDRESS): SYSTEM.ADDRESS;
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
PROCEDURE ["C", "PQgetlength"] GetLength (result: SYSTEM.ADDRESS; row, i: SYSTEM.INT32): SYSTEM.INT32;
PROCEDURE ["C", "PQcmdStatus"] CommandStatus (result: SYSTEM.ADDRESS): SYSTEM.ADDRESS;
PROCEDURE ["C", "PQcmdTuples"] CommandRows (result: SYSTEM.ADDRESS): SYSTEM.ADDRESS;
PROCEDURE ["C", "PQunescapeBytea"] UnescapeBytea (text, length: SYSTEM.ADDRESS): SYSTEM.ADDRESS;
PROCEDURE ["C", "PQfreemem"] FreeMemory (p: SYSTEM.ADDRESS);

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

PROCEDURE ToInt32 (n: LONGINT): SYSTEM.INT32;
(* n, which fits, as an INT32.  SHORT(HUGEINT) is LONGINT under -O2 and
   INTEGER under -OC, 32 bits under both. *)
  VAR wide: HUGEINT;
BEGIN
  wide := n;
  RETURN SHORT(wide)
END ToInt32;

PROCEDURE StartsWith (VAR s: ARRAY OF CHAR; prefix: ARRAY OF CHAR): BOOLEAN;
  VAR i: LONGINT;
BEGIN
  i := 0;
  WHILE (prefix[i] # 0X) & (i < LEN(s)) & (s[i] = prefix[i]) DO INC(i) END;
  RETURN prefix[i] = 0X
END StartsWith;

PROCEDURE ChangesOf (result: SYSTEM.ADDRESS): HUGEINT;
(* The rows that result's command inserted, updated or deleted, from its
   command tag ("INSERT 0 3", "UPDATE 2" ...); 0 for any other command. *)
  VAR tag: ARRAY 16 OF CHAR; n: HUGEINT;
BEGIN
  DbCStrings.Copy(CommandStatus(result), tag);
  n := 0;
  IF StartsWith(tag, "INSERT ") OR StartsWith(tag, "UPDATE ") OR StartsWith(tag, "DELETE ")
     OR StartsWith(tag, "MERGE ") THEN
    IF ParseInt(CommandRows(result), SYSTEM.ADR(n)) = 0 THEN n := 0 END
  END;
  RETURN n
END ChangesOf;

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

PROCEDURE Drain (c: Connection);
(* Read the rest of the active statement's results, if there is one, and
   queue them in it, so that c can send another command. *)
  VAR s: Statement; p: Pending; result: SYSTEM.ADDRESS;
BEGIN
  IF c.active # NIL THEN
    s := c.active; c.active := NIL;
    result := GetResult(c.pg);
    WHILE result # 0 DO
      NEW(p); p.result := result; p.next := NIL;
      IF s.first = NIL THEN s.first := p ELSE s.last.next := p END;
      s.last := p;
      result := GetResult(c.pg)
    END
  END
END Drain;

PROCEDURE NextResult (s: Statement): SYSTEM.ADDRESS;
(* The next result of s's run, from its queue or from the server; 0 if
   there are no more. *)
  VAR c: Connection; result: SYSTEM.ADDRESS;
BEGIN
  c := s.conn(Connection);
  IF s.first # NIL THEN
    result := s.first.result; s.first := s.first.next;
    IF s.first = NIL THEN s.last := NIL END
  ELSIF c.active = s THEN
    result := GetResult(c.pg);
    IF result = 0 THEN c.active := NIL END
  ELSE
    result := 0
  END;
  RETURN result
END NextResult;

PROCEDURE Discard (s: Statement);
(* Free the results of s's run, both those read and those still to come.
   The server sends the rest of a result even so; libpq has no way to stop
   it but cancelling, which could hit the next command instead. *)
  VAR result: SYSTEM.ADDRESS;
BEGIN
  Clear(s.result); s.result := 0;
  result := NextResult(s);
  WHILE result # 0 DO Clear(result); result := NextResult(s) END
END Discard;

PROCEDURE Deallocate (c: Connection; name: StatementName);
(* Drop the prepared statement name on c's server.  PQclosePrepared does
   what DEALLOCATE does, but as a protocol message rather than an SQL
   command, so it works in a transaction that has already failed, where
   the server refuses every command but ROLLBACK. *)
BEGIN
  IF c.pg # 0 THEN Drain(c); Clear(ClosePrepared(c.pg, SYSTEM.ADR(name))) END
END Deallocate;


(* ---- Driver ---- *)

PROCEDURE (d: Driver) Open* (url: ARRAY OF CHAR): Db.Connection;
(* Connect to the database that url names; see the module's comment. *)
  VAR c: Connection;
BEGIN
  NEW(c); c.err := Db.noError; c.msg[0] := 0X; c.prepared := 0; c.active := NIL;
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
  IF c.pg # 0 THEN Finish(c.pg); c.pg := 0; c.active := NIL END
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
  Drain(c);
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
  NEW(st.value, n); NEW(st.address, n); NEW(st.length, n); NEW(st.format, n);
  st.result := 0; st.first := NIL; st.last := NIL;
  st.executed := FALSE; st.done := FALSE; st.row := -1; st.rows := 0; st.changes := 0;
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

PROCEDURE SetValue (s: Statement; i: INTEGER; v: Text; length: LONGINT; format: SYSTEM.INT32);
(* Make v, NIL for NULL, the value of parameter i (1-based): text up to its
   0X in textFormat, or length bytes in binaryFormat. *)
BEGIN
  IF Live(s) THEN
    IF (i < 1) OR (i > s.params.n) THEN
      Db.SetError(s.conn, Db.errRange, "DbPostgres: no such parameter")
    ELSE
      s.value[i - 1] := v; s.length[i - 1] := ToInt32(length); s.format[i - 1] := format
    END
  END
END SetValue;

PROCEDURE (s: Statement) BindNull* (i: INTEGER);
(* Bind NULL to parameter i (1-based). *)
BEGIN
  SetValue(s, i, NIL, 0, textFormat)
END BindNull;

PROCEDURE (s: Statement) BindInt* (i: INTEGER; v: HUGEINT);
(* Bind the integer v to parameter i (1-based), as text. *)
  VAR t: Text;
BEGIN
  NEW(t, numberSize); FormatInt(v, SYSTEM.ADR(t[0]), numberSize);
  SetValue(s, i, t, 0, textFormat)
END BindInt;

PROCEDURE (s: Statement) BindReal* (i: INTEGER; v: LONGREAL);
(* Bind the real number v to parameter i (1-based), as text with enough
   digits to give v back exactly. *)
  VAR t: Text;
BEGIN
  NEW(t, numberSize); FormatReal(v, SYSTEM.ADR(t[0]), numberSize);
  SetValue(s, i, t, 0, textFormat)
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
  SetValue(s, i, t, 0, textFormat)
END BindText;


PROCEDURE (s: Statement) BindBlob* (i: INTEGER; VAR v: ARRAY OF CHAR; n: LONGINT);
(* Bind v[0] .. v[n-1] to parameter i (1-based), in binary format, which
   suits a bytea parameter.  The statement keeps a copy. *)
  VAR t: Text; k: LONGINT;
BEGIN
  IF (n < 0) OR (n > LEN(v)) OR (n > MAX(SYSTEM.INT32)) THEN
    IF Live(s) THEN Db.SetError(s.conn, Db.errRange, "DbPostgres: BindBlob's length is outside the array") END
  ELSE
    IF n = 0 THEN NEW(t, 1) ELSE NEW(t, n) END;   (* so that t[0] exists *)
    FOR k := 0 TO n - 1 DO t[k] := v[k] END;
    SetValue(s, i, t, n, binaryFormat)
  END
END BindBlob;


(* ---- Statement: stepping ---- *)

PROCEDURE Run (s: Statement);
(* Send s, with its current parameters, to the server, and make it c's
   active statement; its results are read as Step needs them. *)
  VAR c: Connection; i: INTEGER;
BEGIN
  c := s.conn(Connection);
  Drain(c);
  FOR i := 0 TO s.params.n - 1 DO
    IF s.value[i] = NIL THEN s.address[i] := 0 ELSE s.address[i] := SYSTEM.ADR(s.value[i][0]) END
  END;
  s.executed := TRUE; s.done := FALSE; s.row := -1; s.rows := 0; s.changes := 0;
  IF SendPrepared(c.pg, SYSTEM.ADR(s.name), s.params.n, SYSTEM.ADR(s.address[0]),
      SYSTEM.ADR(s.length[0]), SYSTEM.ADR(s.format[0]), textFormat) = 0 THEN
    SetResultError(c, 0); s.done := TRUE
  ELSE
    c.active := s;
    (* If libpq refuses chunked rows, the whole result comes as one. *)
    IF SetChunkedRows(c.pg, chunkRows) = 0 THEN END
  END
END Run;

PROCEDURE ReadResult (s: Statement);
(* Replace s.result with the run's next result.  A chunk of rows leaves s
   on the row before its first.  The last result sets s.done, or reports
   the run's error.  The command tag, and so the number of rows changed, is
   on whichever result libpq made when the command completed: the last
   chunk if it was partly filled, else the last result. *)
  VAR c: Connection; result: SYSTEM.ADDRESS; status: SYSTEM.INT32; changes: HUGEINT;
BEGIN
  c := s.conn(Connection);
  Clear(s.result); s.result := 0; s.row := -1; s.rows := 0;
  result := NextResult(s);
  IF result = 0 THEN
    s.done := TRUE;
    Db.SetError(c, Db.errSql, "DbPostgres: the server sent no result")
  ELSE
    status := ResultStatus(result);
    IF (status = tuplesChunk) OR (status = tuplesOk) OR (status = commandOk) THEN
      changes := ChangesOf(result);
      IF changes # 0 THEN s.changes := changes END
    END;
    IF (status = tuplesChunk) OR (status = tuplesOk) THEN
      s.result := result; s.rows := RowCount(result)
    END;
    IF status # tuplesChunk THEN
      s.done := TRUE;
      IF status = emptyQuery THEN Db.SetError(c, Db.errSql, "DbPostgres: no SQL statement")
      ELSIF (status # tuplesOk) & (status # commandOk) THEN SetResultError(c, result)
      END;
      IF status # tuplesOk THEN Clear(result) END;
      (* Read the NULL that ends the run, which frees the connection. *)
      result := NextResult(s);
      WHILE result # 0 DO Clear(result); result := NextResult(s) END
    END
  END
END ReadResult;

PROCEDURE (s: Statement) Step* (): BOOLEAN;
(* Advance to the next row: TRUE if there is one, FALSE when the statement
   is done or has failed (then s.conn.err says which).  The first Step after
   Prepare or Reset sends the statement to the server; a Step that runs off
   the end of a chunk of rows reads the next. *)
BEGIN
  IF ~Live(s) THEN RETURN FALSE END;
  IF ~s.executed THEN Run(s) END;
  IF s.row < s.rows THEN INC(s.row) END;
  WHILE (s.row >= s.rows) & ~s.done & (s.conn.err = Db.noError) DO
    ReadResult(s);
    IF s.row < s.rows THEN INC(s.row) END
  END;
  RETURN s.row < s.rows
END Step;

PROCEDURE (s: Statement) Reset* ;
(* Rewind the statement so it can be stepped again.  Its parameters keep
   their values until they are bound again. *)
BEGIN
  IF Live(s) THEN
    Discard(s);
    s.executed := FALSE; s.done := FALSE; s.row := -1; s.rows := 0; s.changes := 0
  END
END Reset;

PROCEDURE (s: Statement) Finalize* ;
(* Free the statement and deallocate it on the server.  Finalizing it again
   does nothing.  It leaves s.conn.err as it is, so a failed Step is still
   reported after it. *)
BEGIN
  IF s.description # 0 THEN
    Discard(s);
    Clear(s.description); s.description := 0;
    s.executed := FALSE; s.done := FALSE; s.row := -1; s.rows := 0;
    s.value := NIL; s.address := NIL; s.length := NIL; s.format := NIL;
    Deallocate(s.conn(Connection), s.name)
  END
END Finalize;


PROCEDURE (s: Statement) Changes* (): HUGEINT;
(* The rows the statement's last run inserted, updated or deleted, once Step
   has returned FALSE. *)
BEGIN
  IF (s.description = 0) OR ~s.executed OR ~s.done OR (s.row < s.rows) THEN RETURN 0 END;
  RETURN s.changes
END Changes;


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
   typeReal, typeText or typeBlob. *)
  VAR type: SYSTEM.CARD32;
BEGIN
  IF ~OnColumn(s, i) OR IsNull(s, i) THEN RETURN Db.typeNull END;
  type := FieldType(s.result, i);
  IF (type = int2Oid) OR (type = int4Oid) OR (type = int8Oid) THEN RETURN Db.typeInt
  ELSIF (type = float4Oid) OR (type = float8Oid) OR (type = numericOid) THEN RETURN Db.typeReal
  ELSIF type = byteaOid THEN RETURN Db.typeBlob
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

PROCEDURE (s: Statement) ColumnBlob* (i: INTEGER; VAR out: ARRAY OF CHAR): LONGINT;
(* Copy as many of column i's bytes as fit into out and return its whole
   length; 0 for NULL.  A bytea value is unescaped from its text form; any
   other value gives the bytes of its text. *)
  VAR p, bytes: SYSTEM.ADDRESS; wide: HUGEINT; length, n: LONGINT;
BEGIN
  IF ~OnColumn(s, i) OR IsNull(s, i) THEN RETURN 0 END;
  IF FieldType(s.result, i) = byteaOid THEN
    p := UnescapeBytea(GetValue(s.result, s.row, i), SYSTEM.ADR(bytes));
    IF p = 0 THEN Db.SetError(s.conn, Db.errDriver, "DbPostgres: out of memory"); RETURN 0 END;
    wide := bytes; length := SHORT(wide)   (* a bytea holds at most 1 GB *)
  ELSE
    p := GetValue(s.result, s.row, i);
    length := GetLength(s.result, s.row, i)
  END;
  n := length;
  IF n > LEN(out) THEN n := LEN(out) END;
  IF n > 0 THEN SYSTEM.MOVE(p, SYSTEM.ADR(out[0]), n) END;
  IF FieldType(s.result, i) = byteaOid THEN FreeMemory(p) END;
  RETURN length
END ColumnBlob;


BEGIN
  NEW(driver);
  Db.Register(driver, "postgres");
  NEW(alias);
  Db.Register(alias, "postgresql")
END DbPostgres.
