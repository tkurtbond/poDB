MODULE TestDb;
(* Tests of Db's own logic, with MockDriver standing in for a database:
   placeholder translation, opening by scheme, binding by name, reading
   columns by name, Exec, Begin, Commit and Rollback, and booleans, dates
   and times.  It prints one or
   more lines per case; make check compares them with TestDb.expected. *)

IMPORT Db, Out, MockDriver;

TYPE
  OtherDriver = POINTER TO OtherDriverDesc;
  OtherDriverDesc = RECORD (Db.DriverDesc) END;

  LongText = POINTER TO ARRAY 40000 OF CHAR;

VAR
  conn: Db.Connection;
  st: Db.Statement;
  other: OtherDriver;


(* ---- Output helpers ---- *)

PROCEDURE Heading (title: ARRAY OF CHAR);
BEGIN
  Out.Ln; Out.String("== "); Out.String(title); Out.Ln
END Heading;

PROCEDURE Bool (b: BOOLEAN);
BEGIN
  IF b THEN Out.String("TRUE") ELSE Out.String("FALSE") END
END Bool;

PROCEDURE ShowError (c: Db.Connection);
BEGIN
  Out.String("  err="); Out.Int(c.err, 0);
  IF c.err # Db.noError THEN Out.String(" msg="); Out.String(c.msg) END;
  Out.Ln
END ShowError;

PROCEDURE ShowParams (VAR p: Db.Params);
  VAR i: INTEGER;
BEGIN
  Out.String(" n="); Out.Int(p.n, 0);
  Out.String(" named="); Bool(p.named);
  IF p.named THEN
    Out.String(" names=");
    FOR i := 0 TO p.n - 1 DO
      IF i > 0 THEN Out.Char(",") END;
      Out.String(p.name[i])
    END
  END
END ShowParams;


(* ---- Translate ---- *)

PROCEDURE Translate (label, sql: ARRAY OF CHAR; prefix: CHAR; VAR out: ARRAY OF CHAR);
  VAR p: Db.Params;
BEGIN
  Out.String(label); Out.String(": ");
  IF Db.Translate(sql, prefix, out, p) THEN
    Out.String("ok ["); Out.String(out); Out.String("]"); ShowParams(p)
  ELSE
    Out.String("FALSE")
  END;
  Out.Ln
END Translate;

PROCEDURE Repeat (VAR s: ARRAY OF CHAR; head, item, sep: ARRAY OF CHAR; n: LONGINT);
(* s := head item sep item sep ... item, with n items *)
  VAR i, j, k: LONGINT;
  PROCEDURE Add (t: ARRAY OF CHAR);
  BEGIN
    k := 0;
    WHILE t[k] # 0X DO s[i] := t[k]; INC(i); INC(k) END
  END Add;
BEGIN
  i := 0;
  Add(head);
  FOR j := 1 TO n DO
    IF j > 1 THEN Add(sep) END;
    Add(item)
  END;
  s[i] := 0X
END Repeat;

PROCEDURE Append (VAR s: ARRAY OF CHAR; t: ARRAY OF CHAR);
  VAR i, k: LONGINT;
BEGIN
  i := 0;
  WHILE s[i] # 0X DO INC(i) END;
  k := 0;
  REPEAT s[i] := t[k]; INC(i); INC(k) UNTIL t[k - 1] = 0X
END Append;

PROCEDURE Spell (VAR s: ARRAY OF CHAR; t: ARRAY OF CHAR);
(* s := t with ` spelled as ', ~ as " and | as a line feed, since an Oberon
   string cannot hold a quote of its own kind or a control character *)
  VAR i: LONGINT;
BEGIN
  i := 0;
  REPEAT
    IF t[i] = "`" THEN s[i] := "'"
    ELSIF t[i] = "~" THEN s[i] := 22X
    ELSIF t[i] = "|" THEN s[i] := 0AX
    ELSE s[i] := t[i]
    END;
    INC(i)
  UNTIL t[i - 1] = 0X
END Spell;

PROCEDURE TestTranslate;
  VAR out: ARRAY 512 OF CHAR; out9: ARRAY 9 OF CHAR; out10: ARRAY 10 OF CHAR;
      sql: ARRAY 512 OF CHAR; long, longOut: LongText; i: LONGINT; p: Db.Params;
BEGIN
  Heading("Translate");
  Translate("positional ?", "SELECT a FROM t WHERE b = ? AND c = ?", "?", out);
  Translate("positional $", "SELECT a FROM t WHERE b = ? AND c = ?", "$", out);
  Translate("named", "UPDATE t SET a = :a WHERE id = :id", "?", out);
  Translate("repeated name", "SELECT :x + :y_2 + :x", "$", out);
  Translate("no parameters", "SELECT 1", "?", out);
  Translate("cast", "SELECT a::int, :v::text FROM t", "$", out);
  Spell(sql, "SELECT `:no`, `?`, ~a?b~, `:x``s` WHERE a = :yes");
  Translate("quotes", sql, "?", out);
  Spell(sql, "SELECT :a -- what :is ? this|  , :b");
  Translate("line comment", sql, "?", out);
  Translate("block comment", "SELECT /* :a ? */ ?", "?", out);
  Translate("unterminated", "SELECT 'abc", "?", out);
  Translate("mixed", "SELECT ? WHERE a = :a", "?", out);
  Repeat(sql, "SELECT ", "?", ",", 64);
  Translate("64 parameters", sql, "?", out);
  Repeat(sql, "SELECT ", "?", ",", 65);
  Translate("65 parameters", sql, "?", out);
  Repeat(sql, "SELECT :", "a", "", 31);
  Translate("31-character name", sql, "?", out);
  Repeat(sql, "SELECT :", "a", "", 32);
  Translate("32-character name", sql, "?", out);
  Translate("dollar quotes", "SELECT $$ ? :x 'it -- $$, ?", "$", out);
  Translate("tagged dollar quotes", "SELECT $f$ $$ ? $g$ $f$ || :a", "$", out);
  Translate("dollar quotes with no space", "SELECT 1, $$?$$, :a", "$", out);
  Translate("not dollar quotes", "SELECT a$b$, $1, c$$ FROM t WHERE x = :x", "$", out);
  Translate("dollar quote unterminated", "SELECT $q$ ? $$ :a", "$", out);
  Repeat(sql, "SELECT $", "a", "", 31);
  Append(sql, "$ ? $");
  Repeat(out, "", "a", "", 31);
  Append(sql, out); Append(sql, "$ ?");
  Translate("31-character dollar tag", sql, "$", out);
  Repeat(sql, "SELECT $", "a", "", 32);
  Translate("32 characters after $, no closing $", sql, "$", out);
  Append(sql, "$$");
  Translate("32-character dollar tag", sql, "$", out);
  Translate("output fits exactly", "SELECT ?", "?", out10);
  Translate("output one too small", "SELECT ?", "?", out9);

  (* SQL longer than MAX(INTEGER) under -O2 *)
  NEW(long); NEW(longOut);
  Repeat(long^, "SELECT ", " ", "", 35000);
  i := 35007; long[i] := "?"; long[i + 1] := 0X;
  Out.String("35008 characters: ");
  IF Db.Translate(long^, "$", longOut^, p) THEN
    Out.String("ok, ends ["); Out.Char(longOut[i - 1]); Out.Char(longOut[i]);
    Out.Char(longOut[i + 1]); Out.String("]"); ShowParams(p)
  ELSE
    Out.String("FALSE")
  END;
  Out.Ln
END TestTranslate;


(* ---- Open ---- *)

PROCEDURE (d: OtherDriver) Open* (url: ARRAY OF CHAR): Db.Connection;
BEGIN
  Out.String("other: open "); Out.String(url); Out.Ln;
  Db.lastError := "other: refused";
  RETURN NIL
END Open;

PROCEDURE TryOpen (url: ARRAY OF CHAR);
  VAR c: Db.Connection; ok: BOOLEAN;
BEGIN
  ok := Db.Open(url, c);
  Out.String("Open("); Out.String(url); Out.String(") = "); Bool(ok);
  Out.String(" conn # NIL: "); Bool(c # NIL);
  Out.String(" lastError=["); Out.String(Db.lastError); Out.String("]"); Out.Ln;
  IF c # NIL THEN c.Close END
END TryOpen;

PROCEDURE TestOpen;
BEGIN
  Heading("Open");
  TryOpen("nocolon");
  TryOpen(":memory:");
  TryOpen("");
  TryOpen("nosuch:x");
  TryOpen("abcdefghijklmnopqrstuvwxyz012345:x");   (* a 32-character scheme *)
  TryOpen("abcdefghijklmnopqrstuvwxyz01234:x");    (* 31 characters *)
  TryOpen("mock:fail");
  TryOpen("mock:silent");
  TryOpen("other:y");
  TryOpen("mock:ok")
END TestOpen;


(* ---- Binding by name ---- *)

PROCEDURE TestBinding;
  VAR ok: BOOLEAN; blob: ARRAY 3 OF CHAR;
BEGIN
  Heading("Binding by name");
  ok := conn.Prepare("SELECT * FROM t WHERE a = :a AND b = :b OR c = :a", st);
  Out.String("prepare: "); Bool(ok); ShowError(conn);
  Out.String("ParamIndex a="); Out.Int(st.ParamIndex("a"), 0);
  Out.String(" b="); Out.Int(st.ParamIndex("b"), 0);
  Out.String(" zz="); Out.Int(st.ParamIndex("zz"), 0); Out.Ln;
  st.BindIntByName("a", 40); ShowError(conn);
  st.BindIntByName("b", MAX(HUGEINT)); ShowError(conn);
  st.BindIntByName("b", MIN(HUGEINT)); ShowError(conn);
  st.BindTextByName("b", "Ada"); ShowError(conn);
  st.BindRealByName("a", 1.5D0); ShowError(conn);
  st.BindNullByName("b"); ShowError(conn);
  blob[0] := 1X; blob[1] := 0X; blob[2] := 0FFX;
  st.BindBlobByName("a", blob, 3); ShowError(conn);
  st.BindBlobByName("zz", blob, 3); ShowError(conn);
  st.BindIntByName("zz", 1); ShowError(conn);
  st.BindIntByName("A", 1); ShowError(conn);   (* parameter names match exactly *)
  st.Finalize;

  ok := conn.Prepare("SELECT ? + ?", st);
  Out.String("positional prepare: "); Bool(ok); ShowError(conn);
  st.BindInt(2, 7); ShowError(conn);
  st.BindInt(3, 7); ShowError(conn);
  st.BindIntByName("x", 7); ShowError(conn);
  st.Finalize;

  ok := conn.Prepare("SELECT ? WHERE a = :a", st);
  Out.String("mixed prepare: "); Bool(ok); Out.String(" st = NIL: "); Bool(st = NIL);
  ShowError(conn)
END TestBinding;


(* ---- Columns by name ---- *)

PROCEDURE TestColumns;
  VAR ok: BOOLEAN; text: ARRAY 64 OF CHAR; short: ARRAY 3 OF CHAR;
BEGIN
  Heading("Columns by name");
  MockDriver.columns := 4;
  MockDriver.columnName[0] := "Id";
  MockDriver.columnName[1] := "name";
  MockDriver.columnName[2] := "ID";
  MockDriver.columnName[3] := "a23456789b123456789c123456789d123456789e123456789f123456789g12";
  MockDriver.rows := 2;
  MockDriver.value[0, 0] := "1";  MockDriver.value[0, 1] := "Ada";
  MockDriver.value[0, 2] := "10"; MockDriver.value[0, 3] := "-5";
  MockDriver.value[1, 0] := "2";  MockDriver.value[1, 1] := "NULL";
  MockDriver.value[1, 2] := "20"; MockDriver.value[1, 3] := "x";

  ok := conn.Prepare("SELECT", st);
  Out.String("ColumnCount="); Out.Int(st.ColumnCount(), 0); Out.Ln;
  Out.String("ColumnIndex id="); Out.Int(st.ColumnIndex("id"), 0);
  Out.String(" NAME="); Out.Int(st.ColumnIndex("NAME"), 0);
  Out.String(" 63 chars="); Out.Int(st.ColumnIndex("A23456789B123456789C123456789D123456789E123456789F123456789G12"), 0);
  Out.String(" nope="); Out.Int(st.ColumnIndex("nope"), 0); Out.Ln;
  WHILE st.Step() DO
    Out.String("  id="); Out.Int(st.ColumnIntByName("ID"), 0);
    st.ColumnTextByName("Name", text);
    Out.String(" name=["); Out.String(text); Out.String("]");
    Out.String(" type="); Out.Int(st.ColumnTypeByName("name"), 0);
    Out.String(" last="); Out.Int(st.ColumnIntByName("A23456789B123456789C123456789D123456789E123456789F123456789G12"), 0);
    Out.Ln;
    Out.String("  missing int="); Out.Int(st.ColumnIntByName("missing"), 0); ShowError(conn);
    st.ColumnTextByName("missing", text);
    Out.String("  missing text=["); Out.String(text); Out.String("]"); ShowError(conn);
    Out.String("  missing type="); Out.Int(st.ColumnTypeByName("missing"), 0); ShowError(conn);
    st.ColumnTextByName("name", short);
    Out.String("  name in 3 characters=["); Out.String(short); Out.String("]"); Out.Ln;
    Out.String("  IsNull name="); Bool(st.ColumnIsNullByName("name"));
    Out.String(" id="); Bool(st.ColumnIsNull(0));
    Out.String(" BlobByName name="); Out.Int(st.ColumnBlobByName("name", short), 0); Out.Ln;
    Out.String("  missing IsNull="); Bool(st.ColumnIsNullByName("missing")); ShowError(conn);
    Out.String("  missing blob="); Out.Int(st.ColumnBlobByName("missing", short), 0); ShowError(conn)
  END;
  ShowError(conn);
  st.Finalize
END TestColumns;


(* ---- Exec and transactions ---- *)

PROCEDURE TestExec;
  VAR ok: BOOLEAN;
BEGIN
  Heading("Exec and transactions");
  MockDriver.rows := 0;
  Out.String("Begin: "); Bool(conn.Begin()); ShowError(conn);
  Out.String("Commit: "); Bool(conn.Commit()); ShowError(conn);
  Out.String("Rollback: "); Bool(conn.Rollback()); ShowError(conn);
  Out.String("Exec FAIL: "); Bool(conn.Exec("FAIL")); ShowError(conn);
  Out.String("Exec STEPFAIL: "); Bool(conn.Exec("STEPFAIL")); ShowError(conn);
  Out.String("Exec bad placeholders: "); Bool(conn.Exec("SELECT ?, :a")); ShowError(conn);
  ok := conn.Exec("CREATE TABLE t (a INTEGER)");
  Out.String("Exec CREATE: "); Bool(ok); ShowError(conn);
  MockDriver.changes := 3;
  ok := conn.Prepare("DELETE", st);
  Out.String("Changes="); Out.Int(st.Changes(), 0); Out.Ln;
  st.Finalize;
  Out.String("conn.Changes="); Out.Int(conn.Changes(), 0); Out.Ln;
  MockDriver.columns := 1; MockDriver.rows := 2;
  MockDriver.value[0, 0] := "1"; MockDriver.value[1, 0] := "2";
  Out.String("Exec of two rows steps to the end:"); Out.Ln;
  ok := conn.Exec("SELECT");
  Out.String("Exec SELECT: "); Bool(ok); ShowError(conn);
  (* the default PrepareQuery is Prepare, given at least 1 row at a time *)
  Out.String("PrepareQuery of 0 rows: "); Bool(conn.PrepareQuery("SELECT", 0, st)); ShowError(conn);
  Out.String("and no statement: "); Bool(st = NIL); Out.Ln;
  ok := conn.PrepareQuery("SELECT", 10, st);
  Out.String("PrepareQuery of 10 rows: "); Bool(ok); ShowError(conn);
  st.Finalize
END TestExec;


(* ---- Booleans, dates and times ---- *)

PROCEDURE SetDateTime (VAR d: Db.DateTime; year, month, day, hour, minute, second: INTEGER;
    microsecond: LONGINT);
BEGIN
  d.year := year; d.month := month; d.day := day;
  d.hour := hour; d.minute := minute; d.second := second; d.microsecond := microsecond
END SetDateTime;

PROCEDURE ShowDateTime (VAR d: Db.DateTime);
BEGIN
  Out.Int(d.year, 0); Out.Char("/"); Out.Int(d.month, 0); Out.Char("/"); Out.Int(d.day, 0);
  Out.Char(" "); Out.Int(d.hour, 0); Out.Char(":"); Out.Int(d.minute, 0); Out.Char(":");
  Out.Int(d.second, 0); Out.Char("."); Out.Int(d.microsecond, 0)
END ShowDateTime;

PROCEDURE ReadValue (text: ARRAY OF CHAR);
(* Show what ColumnBool and ColumnDateTime make of a column holding text. *)
  VAR ok: BOOLEAN; d: Db.DateTime;
BEGIN
  MockDriver.columns := 1; MockDriver.rows := 1; MockDriver.columnName[0] := "v";
  COPY(text, MockDriver.value[0, 0]);
  ok := conn.Prepare("SELECT", st);
  IF st.Step() THEN
    Out.String("  ["); Out.String(text); Out.String("] bool="); Bool(st.ColumnBoolByName("V"));
    st.ColumnDateTimeByName("v", d);
    Out.String(" date="); ShowDateTime(d); ShowError(conn)
  END;
  st.Finalize
END ReadValue;

PROCEDURE TestTypes;
  VAR ok: BOOLEAN; d: Db.DateTime;
BEGIN
  Heading("Booleans, dates and times");
  ok := conn.Prepare("SELECT :b, :d", st);
  st.BindBoolByName("b", TRUE); ShowError(conn);
  st.BindBool(1, FALSE); ShowError(conn);
  SetDateTime(d, 2026, 10, 28, 14, 30, 5, 0);
  st.BindDateByName("d", d); ShowError(conn);
  st.BindDateTimeByName("d", d); ShowError(conn);
  SetDateTime(d, 1, 1, 1, 0, 0, 0, 5);
  st.BindDateTime(2, d); ShowError(conn);
  SetDateTime(d, 2024, 2, 29, 23, 59, 59, 999999);
  st.BindDateTime(2, d); ShowError(conn);
  SetDateTime(d, 2000, 2, 29, 0, 0, 0, 0);
  st.BindDate(2, d); ShowError(conn);
  Out.String("invalid:"); Out.Ln;
  SetDateTime(d, 2023, 2, 29, 0, 0, 0, 0); st.BindDate(2, d); ShowError(conn);
  SetDateTime(d, 1900, 2, 29, 0, 0, 0, 0); st.BindDate(2, d); ShowError(conn);
  SetDateTime(d, 2026, 4, 31, 0, 0, 0, 0); st.BindDate(2, d); ShowError(conn);
  SetDateTime(d, 10000, 1, 1, 0, 0, 0, 0); st.BindDate(2, d); ShowError(conn);
  SetDateTime(d, 0, 1, 1, 0, 0, 0, 0); st.BindDate(2, d); ShowError(conn);
  SetDateTime(d, 2026, 13, 1, 0, 0, 0, 0); st.BindDate(2, d); ShowError(conn);
  SetDateTime(d, 2026, 1, 1, 24, 0, 0, 0); st.BindDate(2, d); ShowError(conn);
  st.BindDateTime(2, d); ShowError(conn);
  SetDateTime(d, 2026, 1, 1, 0, 60, 0, 0); st.BindDateTime(2, d); ShowError(conn);
  SetDateTime(d, 2026, 1, 1, 0, 0, 60, 0); st.BindDateTime(2, d); ShowError(conn);
  SetDateTime(d, 2026, 1, 1, 0, 0, 0, 1000000); st.BindDateTime(2, d); ShowError(conn);
  SetDateTime(d, 2026, 1, 1, 0, 0, 0, -1); st.BindDateTime(2, d); ShowError(conn);
  st.BindBoolByName("zz", TRUE); ShowError(conn);
  st.BindDateByName("zz", d); ShowError(conn);
  st.BindDateTimeByName("zz", d); ShowError(conn);
  st.Finalize;

  Out.String("reading:"); Out.Ln;
  ReadValue("1");
  ReadValue("0");
  ReadValue("-2");
  ReadValue("NULL");
  ReadValue("2026-10-28");
  ReadValue("2026-10-28 14:30:05");
  ReadValue("2026-10-28T14:30:05");
  ReadValue("2026-10-28 14:30");
  ReadValue("2024-02-29 23:59:59.5");
  ReadValue("2024-02-29 23:59:59.000250");
  ReadValue("2024-02-29 23:59:59.1234567");
  ReadValue("2026-10-28 14:30:05+02");
  ReadValue("2026-10-28 14:30:05.");
  ReadValue("2026-10-28 ");
  ReadValue("2026-10-28 14");
  ReadValue("2026-10-28 14:30:5");
  ReadValue("2026-1-28");
  ReadValue("2023-02-29");
  ReadValue("2026-10-28 24:00:00");
  ReadValue("abc");
  ReadValue("");

  ok := conn.Prepare("SELECT", st);
  IF st.Step() THEN
    Out.String("missing bool="); Bool(st.ColumnBoolByName("missing")); ShowError(conn);
    st.ColumnDateTimeByName("missing", d);
    Out.String("missing date="); ShowDateTime(d); ShowError(conn)
  END;
  st.Finalize
END TestTypes;


BEGIN
  TestTranslate;
  NEW(other); Db.Register(other, "other");
  TestOpen;
  IF ~Db.Open("mock:test", conn) THEN
    Out.String("cannot open mock:test"); Out.Ln; HALT(1)
  END;
  TestBinding;
  TestColumns;
  TestExec;
  TestTypes;
  conn.Close
END TestDb.
