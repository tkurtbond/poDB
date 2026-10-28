MODULE MockDriver;
(* A driver for the scheme "mock:", for testing Db with no database.  It
   prints each call it receives, so a test's output shows what Db passed to
   the driver, and it returns the rows the test puts in columnName and value.
   Values are text; ColumnType calls "NULL" typeNull, an integer typeInt and
   anything else typeText.  ColumnBlob gives a value's characters, and
   Changes gives changes.

   Special URLs: "mock:fail" fails with a message in Db.lastError, and
   "mock:silent" fails without one.  Special SQL: "FAIL" fails in Prepare and
   "STEPFAIL" fails in Step. *)

IMPORT Db, Out;

CONST
  maxColumns* = 8;
  maxRows* = 4;

TYPE
  Connection = POINTER TO ConnectionDesc;
  ConnectionDesc = RECORD (Db.ConnectionDesc) END;

  Statement = POINTER TO StatementDesc;
  StatementDesc = RECORD (Db.StatementDesc)
    sql: ARRAY 256 OF CHAR;   (* after Db.Translate *)
    row: INTEGER              (* the current row, -1 before the first Step *)
  END;

  Driver = POINTER TO DriverDesc;
  DriverDesc = RECORD (Db.DriverDesc) END;

VAR
  columns*, rows*: INTEGER;
  changes*: HUGEINT;
  columnName*: ARRAY maxColumns OF ARRAY 128 OF CHAR;
  value*: ARRAY maxRows, maxColumns OF ARRAY 32 OF CHAR;
  driver: Driver;


(* ---- Driver ---- *)

PROCEDURE (d: Driver) Open* (url: ARRAY OF CHAR): Db.Connection;
  VAR c: Connection;
BEGIN
  IF url = "mock:fail" THEN
    Db.lastError := "mock: cannot open"; RETURN NIL
  ELSIF url = "mock:silent" THEN
    RETURN NIL
  END;
  Out.String("mock: open "); Out.String(url); Out.Ln;
  NEW(c); c.err := Db.noError; c.msg[0] := 0X;
  RETURN c
END Open;


(* ---- Connection ---- *)

PROCEDURE (c: Connection) Close* ;
BEGIN
  Out.String("mock: close"); Out.Ln
END Close;

PROCEDURE (c: Connection) Prepare* (sql: ARRAY OF CHAR; VAR s: Db.Statement): BOOLEAN;
  VAR st: Statement;
BEGIN
  c.err := Db.noError;
  s := NIL;
  NEW(st);
  IF ~Db.Translate(sql, "?", st.sql, st.params) THEN
    Db.SetError(c, Db.errSql, "mock: bad placeholders"); RETURN FALSE
  END;
  Out.String("mock: prepare "); Out.String(st.sql); Out.Ln;
  IF st.sql = "FAIL" THEN
    Db.SetError(c, Db.errSql, "mock: prepare failed"); RETURN FALSE
  END;
  st.conn := c; st.row := -1;
  s := st;
  RETURN TRUE
END Prepare;


(* ---- Statement ---- *)

PROCEDURE CheckParam (s: Statement; i: INTEGER): BOOLEAN;
BEGIN
  s.conn.err := Db.noError;
  IF (i < 1) OR (i > s.params.n) THEN
    Db.SetError(s.conn, Db.errRange, "mock: no such parameter"); RETURN FALSE
  END;
  RETURN TRUE
END CheckParam;

PROCEDURE ShowBind (kind: ARRAY OF CHAR; i: INTEGER);
BEGIN
  Out.String("mock: bind "); Out.String(kind); Out.Char(" "); Out.Int(i, 0)
END ShowBind;

PROCEDURE (s: Statement) BindNull* (i: INTEGER);
BEGIN
  IF CheckParam(s, i) THEN ShowBind("null", i); Out.Ln END
END BindNull;

PROCEDURE (s: Statement) BindInt* (i: INTEGER; v: HUGEINT);
BEGIN
  IF CheckParam(s, i) THEN ShowBind("int", i); Out.String(" = "); Out.Int(v, 0); Out.Ln END
END BindInt;

PROCEDURE (s: Statement) BindReal* (i: INTEGER; v: LONGREAL);
BEGIN
  IF CheckParam(s, i) THEN
    ShowBind("real", i); Out.String(" = "); Out.Int(ENTIER(v * 1000), 0); Out.String("/1000"); Out.Ln
  END
END BindReal;

PROCEDURE (s: Statement) BindText* (i: INTEGER; v: ARRAY OF CHAR);
BEGIN
  IF CheckParam(s, i) THEN ShowBind("text", i); Out.String(" = "); Out.String(v); Out.Ln END
END BindText;

PROCEDURE (s: Statement) BindBlob* (i: INTEGER; VAR v: ARRAY OF CHAR; n: LONGINT);
  VAR k: LONGINT;
BEGIN
  IF CheckParam(s, i) THEN
    ShowBind("blob", i); Out.String(" =");
    FOR k := 0 TO n - 1 DO Out.Char(" "); Out.Int(ORD(v[k]), 0) END;
    Out.Ln
  END
END BindBlob;

PROCEDURE (s: Statement) Step* (): BOOLEAN;
BEGIN
  s.conn.err := Db.noError;
  Out.String("mock: step"); Out.Ln;
  IF s.sql = "STEPFAIL" THEN
    Db.SetError(s.conn, Db.errSql, "mock: step failed"); RETURN FALSE
  END;
  IF s.row < rows THEN INC(s.row) END;
  RETURN s.row < rows
END Step;

PROCEDURE (s: Statement) Reset* ;
BEGIN
  Out.String("mock: reset"); Out.Ln;
  s.row := -1
END Reset;

PROCEDURE (s: Statement) Finalize* ;
BEGIN
  Out.String("mock: finalize"); Out.Ln
END Finalize;

PROCEDURE (s: Statement) ColumnCount* (): INTEGER;
BEGIN
  RETURN columns
END ColumnCount;

PROCEDURE CheckColumn (s: Statement; i: INTEGER): BOOLEAN;
BEGIN
  IF (i < 0) OR (i >= columns) OR (s.row < 0) OR (s.row >= rows) THEN
    Db.SetError(s.conn, Db.errRange, "mock: no such column or row"); RETURN FALSE
  END;
  RETURN TRUE
END CheckColumn;

PROCEDURE (s: Statement) ColumnName* (i: INTEGER; VAR out: ARRAY OF CHAR);
BEGIN
  IF (i >= 0) & (i < columns) THEN COPY(columnName[i], out) ELSE out[0] := 0X END
END ColumnName;

PROCEDURE IsInteger (v: ARRAY OF CHAR): BOOLEAN;
  VAR i: LONGINT;
BEGIN
  i := 0;
  IF v[0] = "-" THEN i := 1 END;
  IF v[i] = 0X THEN RETURN FALSE END;
  WHILE (v[i] >= "0") & (v[i] <= "9") DO INC(i) END;
  RETURN v[i] = 0X
END IsInteger;

PROCEDURE (s: Statement) ColumnType* (i: INTEGER): INTEGER;
BEGIN
  IF ~CheckColumn(s, i) OR (value[s.row, i] = "NULL") THEN RETURN Db.typeNull
  ELSIF IsInteger(value[s.row, i]) THEN RETURN Db.typeInt
  ELSE RETURN Db.typeText
  END
END ColumnType;

PROCEDURE (s: Statement) ColumnInt* (i: INTEGER): HUGEINT;
  VAR n: HUGEINT; k: LONGINT; negative: BOOLEAN;
BEGIN
  IF ~CheckColumn(s, i) OR ~IsInteger(value[s.row, i]) THEN RETURN 0 END;
  n := 0; k := 0; negative := value[s.row, i][0] = "-";
  IF negative THEN k := 1 END;
  WHILE value[s.row, i][k] # 0X DO
    n := n * 10 + (ORD(value[s.row, i][k]) - ORD("0")); INC(k)
  END;
  IF negative THEN n := -n END;
  RETURN n
END ColumnInt;

PROCEDURE (s: Statement) ColumnReal* (i: INTEGER): LONGREAL;
BEGIN
  RETURN s.ColumnInt(i)
END ColumnReal;

PROCEDURE (s: Statement) ColumnText* (i: INTEGER; VAR out: ARRAY OF CHAR);
BEGIN
  IF ~CheckColumn(s, i) OR (value[s.row, i] = "NULL") THEN out[0] := 0X
  ELSE COPY(value[s.row, i], out)
  END
END ColumnText;

PROCEDURE (s: Statement) ColumnBlob* (i: INTEGER; VAR out: ARRAY OF CHAR): LONGINT;
  VAR k: LONGINT;
BEGIN
  IF ~CheckColumn(s, i) OR (value[s.row, i] = "NULL") THEN RETURN 0 END;
  k := 0;
  WHILE value[s.row, i][k] # 0X DO
    IF k < LEN(out) THEN out[k] := value[s.row, i][k] END;
    INC(k)
  END;
  RETURN k
END ColumnBlob;

PROCEDURE (s: Statement) Changes* (): HUGEINT;
BEGIN
  RETURN changes
END Changes;

BEGIN
  columns := 0; rows := 0; changes := 0;
  NEW(driver);
  Db.Register(driver, "mock")
END MockDriver.
