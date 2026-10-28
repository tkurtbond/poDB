MODULE TestDb;
(* Tests of Db's own logic, with MockDriver standing in for a database:
   placeholder translation, opening by scheme, binding by name, reading
   columns by name, and Exec, Begin, Commit and Rollback.  It prints one or
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
  VAR ok: BOOLEAN;
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
    Out.String("  name in 3 characters=["); Out.String(short); Out.String("]"); Out.Ln
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
  Out.String("Exec CREATE: "); Bool(ok); ShowError(conn)
END TestExec;


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
  conn.Close
END TestDb.
