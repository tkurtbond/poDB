MODULE Conformance;
(* The tests every driver must pass, written once against Db and run with
   each driver's URL:

     Conformance sqlite::memory:
     Conformance 'postgres:///podb_test?host=/path/to/socket&user=podb'

   It imports both drivers, so the URL alone picks the driver.

   It uses only SQL that SQLite and PostgreSQL both accept (design, section
   4), works in tables of its own, podb_conformance and podb_blobs (BYTEA is
   PostgreSQL's BLOB type, and a name SQLite accepts), and prints one line per
   case, which make compares with Conformance.expected.  Error messages
   differ between databases, so it prints error codes, never messages. *)

IMPORT Db, Out, Args, DbSqlite, DbPostgres;

CONST
  table = "podb_conformance";

VAR
  url: ARRAY 256 OF CHAR;
  conn: Db.Connection;


(* ---- Output helpers ---- *)

PROCEDURE Heading (title: ARRAY OF CHAR);
BEGIN
  Out.Ln; Out.String("== "); Out.String(title); Out.Ln
END Heading;

PROCEDURE Check (label: ARRAY OF CHAR; ok: BOOLEAN);
(* label: ok, or label: FAIL with the connection's error *)
BEGIN
  Out.String(label); Out.String(": ");
  IF ok THEN Out.String("ok")
  ELSE
    Out.String("FAIL");
    IF conn.err # Db.noError THEN
      Out.String(" err="); Out.Int(conn.err, 0); Out.String(" "); Out.String(conn.msg)
    END
  END;
  Out.Ln
END Check;

PROCEDURE Error (label: ARRAY OF CHAR; result: BOOLEAN);
(* label, the result of a call expected to fail, and the error code *)
BEGIN
  Out.String(label); Out.String(": ");
  IF result THEN Out.String("TRUE") ELSE Out.String("FALSE") END;
  Out.String(" err="); Out.Int(conn.err, 0); Out.Ln
END Error;

PROCEDURE Setup (sql: ARRAY OF CHAR);
(* Run sql, which the tests depend on, and stop if it fails. *)
BEGIN
  IF ~conn.Exec(sql) THEN
    Out.String("setup failed: "); Out.String(sql); Out.Ln;
    Out.String("  "); Out.String(conn.msg); Out.Ln;
    HALT(1)
  END
END Setup;

PROCEDURE Prepare (sql: ARRAY OF CHAR; VAR s: Db.Statement);
(* Prepare sql, which the tests depend on, and stop if that fails. *)
BEGIN
  IF ~conn.Prepare(sql, s) THEN
    Out.String("prepare failed: "); Out.String(sql); Out.Ln;
    Out.String("  "); Out.String(conn.msg); Out.Ln;
    HALT(1)
  END
END Prepare;

PROCEDURE Count (): HUGEINT;
(* the number of rows in the table *)
  VAR s: Db.Statement; n: HUGEINT;
BEGIN
  Prepare("SELECT COUNT(*) FROM podb_conformance", s);
  n := -1;
  IF s.Step() THEN n := s.ColumnInt(0) END;
  s.Finalize;
  RETURN n
END Count;

PROCEDURE TextOf (id: HUGEINT; VAR text: ARRAY OF CHAR): INTEGER;
(* the name in row id, and its type *)
  VAR s: Db.Statement; type: INTEGER;
BEGIN
  Prepare("SELECT name FROM podb_conformance WHERE id = ?", s);
  s.BindInt(1, id);
  text[0] := 0X; type := -1;
  IF s.Step() THEN s.ColumnText(0, text); type := s.ColumnType(0) END;
  s.Finalize;
  RETURN type
END TextOf;


(* ---- Creating, inserting, selecting, updating, deleting ---- *)

PROCEDURE TestBasics;
  VAR s: Db.Statement; name: ARRAY 64 OF CHAR; ok: BOOLEAN;
BEGIN
  Heading("Basics");
  Prepare("INSERT INTO podb_conformance (id, name, n, r) VALUES (:id, :name, :n, :r)", s);
  s.BindIntByName("id", 1); s.BindTextByName("name", "Ada");
  s.BindIntByName("n", 36); s.BindRealByName("r", 1.5D0);
  ok := ~s.Step() & (conn.err = Db.noError);
  s.Finalize;
  Check("insert with names", ok);

  Prepare("INSERT INTO podb_conformance (id, name, n, r) VALUES (?, ?, ?, ?)", s);
  s.BindInt(1, 2); s.BindText(2, "Niklaus"); s.BindInt(3, 90); s.BindReal(4, 2.25D0);
  ok := ~s.Step() & (conn.err = Db.noError);
  s.Reset;
  s.BindInt(1, 3); s.BindText(2, "Edsger"); s.BindInt(3, 72); s.BindNull(4);
  ok := ok & ~s.Step() & (conn.err = Db.noError);
  s.Finalize;
  Check("insert by position, twice through one statement", ok);

  Prepare("SELECT id, name, n FROM podb_conformance ORDER BY id", s);
  WHILE s.Step() DO
    s.ColumnText(1, name);
    Out.String("  "); Out.Int(s.ColumnInt(0), 0); Out.String(" "); Out.String(name);
    Out.String(" "); Out.Int(s.ColumnInt(2), 0); Out.Ln
  END;
  Check("select", conn.err = Db.noError);
  s.Finalize;

  Prepare("SELECT COUNT(*) FROM podb_conformance WHERE id >= :lo AND n >= :lo", s);
  s.BindIntByName("lo", 2);
  ok := s.Step() & (s.ColumnInt(0) = 2);
  s.Finalize;
  Check("one name used twice", ok);

  Prepare("UPDATE podb_conformance SET n = n + :d WHERE id = :id", s);
  s.BindIntByName("d", 1); s.BindIntByName("id", 1);
  ok := ~s.Step() & (conn.err = Db.noError);
  s.Finalize;
  Prepare("SELECT n FROM podb_conformance WHERE id = 1", s);
  ok := ok & s.Step() & (s.ColumnInt(0) = 37);
  s.Finalize;
  Check("update", ok);

  Prepare("DELETE FROM podb_conformance WHERE id = ?", s);
  s.BindInt(1, 3);
  ok := ~s.Step() & (conn.err = Db.noError);
  s.Finalize;
  Check("delete", ok & (Count() = 2))
END TestBasics;


(* ---- Columns ---- *)

PROCEDURE TestColumns;
  VAR s: Db.Statement; i: INTEGER; v: HUGEINT; text: ARRAY 64 OF CHAR;
BEGIN
  Heading("Columns");
  Prepare("SELECT id, name, n, r FROM podb_conformance WHERE id = 1", s);
  Out.String("ColumnCount="); Out.Int(s.ColumnCount(), 0); Out.String(" names=");
  FOR i := 0 TO s.ColumnCount() - 1 DO
    s.ColumnName(i, text);
    IF i > 0 THEN Out.Char(",") END;
    Out.String(text)
  END;
  Out.Ln;
  IF s.Step() THEN
    Out.String("types=");
    FOR i := 0 TO 3 DO
      IF i > 0 THEN Out.Char(",") END;
      Out.Int(s.ColumnType(i), 0)
    END;
    Out.Ln;
    s.ColumnText(2, text);
    Out.String("an integer as text=["); Out.String(text); Out.String("]"); Out.Ln;
    s.ColumnText(3, text);
    Out.String("a real as text=["); Out.String(text); Out.String("]"); Out.Ln;
    Check("an integer as a real", s.ColumnReal(2) = 37.0D0);
    Check("by name", (s.ColumnIntByName("N") = 37) & (s.ColumnRealByName("r") = 1.5D0));
    v := s.ColumnInt(4);
    Error("column 4 of 4", FALSE);
    v := s.ColumnInt(-1);
    Error("column -1", FALSE)
  ELSE
    Check("step", FALSE)
  END;
  s.Finalize
END TestColumns;


(* ---- Round trips ---- *)

PROCEDURE IntegerRoundTrip (label: ARRAY OF CHAR; id, v: HUGEINT);
  VAR s: Db.Statement; back: HUGEINT; ok: BOOLEAN;
BEGIN
  Prepare("INSERT INTO podb_conformance (id, n) VALUES (?, ?)", s);
  s.BindInt(1, id); s.BindInt(2, v);
  ok := ~s.Step() & (conn.err = Db.noError);
  s.Finalize;
  Prepare("SELECT n FROM podb_conformance WHERE id = ?", s);
  s.BindInt(1, id);
  back := 0;
  ok := ok & s.Step();
  IF ok THEN back := s.ColumnInt(0) END;
  s.Finalize;
  Out.String(label); Out.String(" "); Out.Int(back, 0); Out.String(": ");
  IF ok & (back = v) THEN Out.String("ok") ELSE Out.String("FAIL") END;
  Out.Ln
END IntegerRoundTrip;

PROCEDURE RealRoundTrip (label: ARRAY OF CHAR; id: HUGEINT; v: LONGREAL);
  VAR s: Db.Statement; back: LONGREAL; ok: BOOLEAN;
BEGIN
  Prepare("INSERT INTO podb_conformance (id, r) VALUES (?, ?)", s);
  s.BindInt(1, id); s.BindReal(2, v);
  ok := ~s.Step() & (conn.err = Db.noError);
  s.Finalize;
  Prepare("SELECT r FROM podb_conformance WHERE id = ?", s);
  s.BindInt(1, id);
  back := 0;
  ok := ok & s.Step();
  IF ok THEN back := s.ColumnReal(0) END;
  s.Finalize;
  Check(label, ok & (back = v))
END RealRoundTrip;

PROCEDURE TestRoundTrips;
BEGIN
  Heading("Round trips");
  IntegerRoundTrip("MAX(HUGEINT)", 10, MAX(HUGEINT));
  IntegerRoundTrip("MIN(HUGEINT)", 11, MIN(HUGEINT));
  IntegerRoundTrip("zero", 12, 0);
  IntegerRoundTrip("-1", 13, -1);
  RealRoundTrip("0.1", 20, 0.1D0);
  RealRoundTrip("1/3", 21, 1.0D0 / 3.0D0);
  RealRoundTrip("1e300", 22, 1.0D300);
  RealRoundTrip("-2.5e-300", 23, -2.5D-300);
  RealRoundTrip("123456789.123456789", 24, 123456789.123456789D0);
  RealRoundTrip("0.1 + 0.2", 25, 0.1D0 + 0.2D0);   (* prints as 0.3 only to 16 digits *)
  RealRoundTrip("-0.0", 26, -0.0D0)
END TestRoundTrips;


(* ---- NULL ---- *)

PROCEDURE TestNull;
  VAR s: Db.Statement; text: ARRAY 16 OF CHAR; ok: BOOLEAN;
BEGIN
  Heading("NULL");
  Prepare("INSERT INTO podb_conformance (id, name, n, r) VALUES (:id, :name, :n, :r)", s);
  s.BindIntByName("id", 30); s.BindNullByName("name");
  s.BindNullByName("n"); s.BindNullByName("r");
  ok := ~s.Step() & (conn.err = Db.noError);
  s.Finalize;
  Check("insert NULLs", ok);
  Prepare("SELECT name, n, r FROM podb_conformance WHERE id = 30", s);
  IF s.Step() THEN
    text := "unchanged";
    s.ColumnText(0, text);
    Out.String("types="); Out.Int(s.ColumnType(0), 0); Out.Char(",");
    Out.Int(s.ColumnType(1), 0); Out.Char(","); Out.Int(s.ColumnType(2), 0);
    Out.String(" text=["); Out.String(text); Out.String("] int="); Out.Int(s.ColumnInt(1), 0);
    Out.Ln;
    Check("NULL as a real is 0", s.ColumnReal(2) = 0.0D0);
    Check("ColumnIsNull", s.ColumnIsNull(0) & s.ColumnIsNull(2) & s.ColumnIsNullByName("N"));
    Check("reading NULL is no error", conn.err = Db.noError)
  ELSE
    Check("step", FALSE)
  END;
  s.Finalize;
  Prepare("SELECT COUNT(*) FROM podb_conformance WHERE name IS NULL AND id = 30", s);
  Check("IS NULL", s.Step() & (s.ColumnInt(0) = 1));
  Check("ColumnIsNull of a value", ~s.ColumnIsNull(0) & (conn.err = Db.noError));
  s.Finalize
END TestNull;


(* ---- Text ---- *)

PROCEDURE TextRoundTrip (label: ARRAY OF CHAR; id: HUGEINT; v: ARRAY OF CHAR);
  VAR s: Db.Statement; back: ARRAY 64 OF CHAR; ok: BOOLEAN; type: INTEGER;
BEGIN
  Prepare("INSERT INTO podb_conformance (id, name) VALUES (?, ?)", s);
  s.BindInt(1, id); s.BindText(2, v);
  ok := ~s.Step() & (conn.err = Db.noError);
  s.Finalize;
  type := TextOf(id, back);
  Out.String(label); Out.String(" ["); Out.String(back); Out.String("] type=");
  Out.Int(type, 0); Out.String(": ");
  IF ok & (back = v) THEN Out.String("ok") ELSE Out.String("FAIL") END;
  Out.Ln
END TextRoundTrip;

PROCEDURE TestText;
  VAR utf8: ARRAY 8 OF CHAR; short: ARRAY 5 OF CHAR; back: ARRAY 64 OF CHAR;
      type: INTEGER;
BEGIN
  Heading("Text");
  TextRoundTrip("empty", 40, "");
  TextRoundTrip("single quote", 41, "O'Brien");
  TextRoundTrip("double quotes", 42, 'say "hi"');
  TextRoundTrip("placeholders and a comment", 43, "-- :x ? $1 /*");
  utf8[0] := "n"; utf8[1] := "a"; utf8[2] := 0C3X; utf8[3] := 0AFX;   (* i with diaeresis *)
  utf8[4] := "v"; utf8[5] := "e"; utf8[6] := 0X;
  TextRoundTrip("UTF-8", 44, utf8);

  Setup("INSERT INTO podb_conformance (id, name) VALUES (45, 'it''s -- :x ? /* */')");
  type := TextOf(45, back);
  Out.String("placeholders in a literal ["); Out.String(back); Out.String("]"); Out.Ln;

  type := TextOf(2, short);
  Out.String("truncated ["); Out.String(short); Out.String("]"); Out.Ln
END TestText;


(* ---- Transactions ---- *)

PROCEDURE TestTransactions;
  VAR before: HUGEINT;
BEGIN
  Heading("Transactions");
  before := Count();
  Check("begin", conn.Begin());
  Setup("INSERT INTO podb_conformance (id, name) VALUES (50, 'rolled back')");
  Check("rollback", conn.Rollback());
  Check("no row after rollback", Count() = before);
  Check("begin", conn.Begin());
  Setup("INSERT INTO podb_conformance (id, name) VALUES (51, 'committed')");
  Check("commit", conn.Commit());
  Check("one row after commit", Count() = before + 1)
END TestTransactions;


(* ---- Errors ---- *)

PROCEDURE TestErrors;
  VAR s: Db.Statement; ok: BOOLEAN;
BEGIN
  Heading("Errors");
  ok := conn.Prepare("SELEC 1", s);
  Error("syntax error", ok);
  Out.String("  statement is NIL: "); IF s = NIL THEN Out.String("TRUE") ELSE Out.String("FALSE") END; Out.Ln;
  Error("duplicate primary key", conn.Exec("INSERT INTO podb_conformance (id) VALUES (1)"));
  ok := conn.Prepare("SELECT nosuch FROM podb_conformance", s);
  Error("no such column", ok);
  ok := conn.Prepare("SELECT * FROM podb_nosuch", s);
  Error("no such table", ok);
  ok := conn.Prepare("SELECT 1; SELECT 2", s);
  Error("two statements", ok);
  Prepare("SELECT name FROM podb_conformance WHERE id = ?", s);
  s.BindInt(2, 1);
  Error("bind parameter 2 of 1", FALSE);
  s.BindInt(0, 1);
  Error("bind parameter 0", FALSE);
  s.BindText(1, "x");
  Error("bind parameter 1", FALSE);
  s.BindIntByName("x", 1);
  Error("bind an unknown name", FALSE);
  s.Finalize;
  Error("finalize keeps the error", FALSE);
  s.Finalize;
  Check("usable after errors and a second Finalize", Count() > 0)
END TestErrors;


(* ---- Reusing a statement ---- *)

PROCEDURE TestReuse;
  VAR s: Db.Statement; name: ARRAY 64 OF CHAR; id: HUGEINT;
BEGIN
  Heading("Reuse");
  Prepare("SELECT name FROM podb_conformance WHERE id = :id", s);
  FOR id := 1 TO 2 DO
    s.BindIntByName("id", id);
    IF s.Step() THEN s.ColumnText(0, name) ELSE name := "(none)" END;
    Out.String("  "); Out.Int(id, 0); Out.String(" "); Out.String(name); Out.Ln;
    s.Reset
  END;
  s.BindIntByName("id", 1);
  IF s.Step() & s.Step() THEN Out.String("FAIL: a second row") ELSE Out.String("one row") END;
  Out.Ln;
  Check("stepping past the end is no error", conn.err = Db.noError);
  s.Finalize
END TestReuse;


(* ---- RETURNING ---- *)

PROCEDURE TestReturning;
  VAR s: Db.Statement; ok: BOOLEAN;
BEGIN
  Heading("RETURNING");
  Prepare("INSERT INTO podb_conformance (id, name) VALUES (?, ?) RETURNING id, name", s);
  s.BindInt(1, 60); s.BindText(2, "returned");
  ok := s.Step() & (s.ColumnInt(0) = 60);
  ok := ok & ~s.Step() & (conn.err = Db.noError);
  s.Finalize;
  Check("INSERT ... RETURNING", ok)
END TestReturning;


(* ---- Changes ---- *)

PROCEDURE Changes (label, sql: ARRAY OF CHAR);
(* Run sql, which returns no rows, and print Changes before and after. *)
  VAR s: Db.Statement; before: HUGEINT; ok: BOOLEAN;
BEGIN
  Prepare(sql, s);
  before := s.Changes();
  ok := ~s.Step() & (conn.err = Db.noError);
  Out.String(label); Out.String(": "); Out.Int(before, 0); Out.String(" then ");
  Out.Int(s.Changes(), 0);
  s.Reset;
  Out.String(", after Reset "); Out.Int(s.Changes(), 0);
  IF ~ok THEN Out.String(" FAIL") END;
  Out.Ln;
  s.Finalize
END Changes;

PROCEDURE TestChanges;
  VAR s: Db.Statement; ok: BOOLEAN;
BEGIN
  Heading("Changes");
  Changes("insert", "INSERT INTO podb_conformance (id, name) VALUES (70, 'c'), (71, 'c'), (72, 'c')");
  Changes("update 3", "UPDATE podb_conformance SET n = 7 WHERE name = 'c'");
  Changes("update none", "UPDATE podb_conformance SET n = 7 WHERE id < 0");
  Changes("select", "SELECT id FROM podb_conformance WHERE id < 0");
  Changes("delete 2", "DELETE FROM podb_conformance WHERE id IN (70, 71)");
  Changes("create", "CREATE TABLE podb_changes (a INTEGER)");
  Changes("drop", "DROP TABLE podb_changes");

  Prepare("SELECT id FROM podb_conformance WHERE id = 72", s);
  ok := s.Step() & (s.Changes() = 0) & ~s.Step() & (s.Changes() = 0);
  s.Finalize;
  Check("a select changes nothing", ok);

  Prepare("UPDATE podb_conformance SET n = 8 WHERE id = 72 RETURNING id", s);
  ok := s.Step() & (s.Changes() = 0) & ~s.Step() & (s.Changes() = 1) & (conn.err = Db.noError);
  s.Finalize;
  Check("UPDATE ... RETURNING counts once done", ok);

  Prepare("DELETE FROM podb_conformance WHERE id = ?", s);
  s.BindInt(1, 72);
  ok := ~s.Step() & (s.Changes() = 1);
  s.Reset; s.BindInt(1, 72);
  ok := ok & ~s.Step() & (s.Changes() = 0);
  s.Finalize;
  Check("each run counts its own rows", ok)
END TestChanges;


(* ---- BLOBs ---- *)

PROCEDURE ShowBlob (VAR b: ARRAY OF CHAR; n: LONGINT);
  VAR k: LONGINT;
BEGIN
  Out.String(" bytes=");
  FOR k := 0 TO n - 1 DO
    IF k > 0 THEN Out.Char(",") END;
    Out.Int(ORD(b[k]), 0)
  END
END ShowBlob;

PROCEDURE TestBlobs;
  VAR s: Db.Statement; blob, back: ARRAY 8 OF CHAR; short: ARRAY 2 OF CHAR;
      n: LONGINT; ok: BOOLEAN;
BEGIN
  Heading("BLOBs");
  Setup("CREATE TABLE podb_blobs (id INTEGER PRIMARY KEY, b BYTEA)");
  blob[0] := 0X; blob[1] := 1X; blob[2] := 0FFX; blob[3] := 0X; blob[4] := "A";
  blob[5] := "\"; blob[6] := "'"; blob[7] := 0X;
  Prepare("INSERT INTO podb_blobs (id, b) VALUES (:id, :b)", s);
  s.BindIntByName("id", 1); s.BindBlobByName("b", blob, 7);
  ok := ~s.Step() & (conn.err = Db.noError);
  s.Reset;
  s.BindIntByName("id", 2); s.BindBlob(2, blob, 0);
  ok := ok & ~s.Step() & (conn.err = Db.noError);
  s.Reset;
  s.BindIntByName("id", 3); s.BindNull(2);
  ok := ok & ~s.Step() & (conn.err = Db.noError);
  Check("insert a BLOB, an empty one and NULL", ok);

  s.Reset;
  s.BindBlob(2, blob, -1);
  Error("BindBlob of -1 bytes", FALSE);
  s.BindBlob(2, blob, 9);
  Error("BindBlob of 9 bytes from 8", FALSE);
  s.BindBlob(3, blob, 1);
  Error("BindBlob to parameter 3 of 2", FALSE);
  s.Finalize;

  Prepare("SELECT id, b FROM podb_blobs ORDER BY id", s);
  WHILE s.Step() DO
    back[0] := "x";
    n := s.ColumnBlob(1, back);
    Out.String("  "); Out.Int(s.ColumnInt(0), 0); Out.String(" type=");
    Out.Int(s.ColumnType(1), 0); Out.String(" IsNull=");
    IF s.ColumnIsNull(1) THEN Out.String("TRUE") ELSE Out.String("FALSE") END;
    Out.String(" length="); Out.Int(n, 0); ShowBlob(back, n);
    IF n = 7 THEN
      n := s.ColumnBlobByName("B", short);
      Out.String(" into 2 bytes: length="); Out.Int(n, 0); ShowBlob(short, 2)
    END;
    Out.Ln
  END;
  Check("select BLOBs", conn.err = Db.noError);
  s.Finalize;

  Prepare("SELECT name, n FROM podb_conformance WHERE id = 1", s);
  IF s.Step() THEN
    n := s.ColumnBlob(0, back);
    Out.String("text as a BLOB: length="); Out.Int(n, 0); ShowBlob(back, n); Out.Ln;
    n := s.ColumnBlob(1, back);
    Out.String("an integer as a BLOB: length="); Out.Int(n, 0); ShowBlob(back, n); Out.Ln
  ELSE
    Check("step", FALSE)
  END;
  s.Finalize;
  Setup("DROP TABLE podb_blobs")
END TestBlobs;


(* ---- Long results ---- *)

PROCEDURE Series (VAR s: Db.Statement);
(* Prepare a select of the 250 rows 1 .. 250, more than a PostgreSQL chunk. *)
BEGIN
  Prepare("WITH RECURSIVE series (i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM series WHERE i < 250) SELECT i FROM series", s)
END Series;

PROCEDURE ShowSum (label: ARRAY OF CHAR; rows, sum: HUGEINT);
(* label: the rows read, their sum, and the connection's error *)
BEGIN
  Out.String(label); Out.String(": rows="); Out.Int(rows, 0);
  Out.String(" sum="); Out.Int(sum, 0); Out.String(" err="); Out.Int(conn.err, 0); Out.Ln
END ShowSum;

PROCEDURE TestLong;
  VAR a, b, insert: Db.Statement; rows, sum, other: HUGEINT; more, ok: BOOLEAN;
BEGIN
  Heading("Long results");
  Series(a);
  rows := 0; sum := 0;
  WHILE a.Step() DO INC(rows); INC(sum, a.ColumnInt(0)) END;
  ShowSum("a long result", rows, sum);

  (* write to the database while the rows are arriving *)
  Prepare("INSERT INTO podb_conformance (id, name) VALUES (?, 'long')", insert);
  a.Reset;
  rows := 0; sum := 0; ok := TRUE;
  WHILE a.Step() DO
    INC(rows); INC(sum, a.ColumnInt(0));
    IF rows MOD 50 = 0 THEN
      insert.BindInt(1, 1000 + rows);
      ok := ok & ~insert.Step() & (conn.err = Db.noError);
      insert.Reset;
      ok := ok & (Count() > 0)
    END
  END;
  ShowSum("writes while stepping", rows, sum);
  Check("each write", ok);
  insert.Finalize;
  Changes("delete what they wrote", "DELETE FROM podb_conformance WHERE id >= 1000");

  (* two long results stepped in turn *)
  a.Reset;
  Series(b);
  rows := 0; sum := 0; other := 0; more := TRUE;
  WHILE more DO
    more := a.Step();
    IF more THEN INC(rows); INC(sum, a.ColumnInt(0)) END;
    IF b.Step() THEN INC(other, b.ColumnInt(0)) END
  END;
  ShowSum("two at once, the first", rows, sum);
  ShowSum("two at once, the second", 250, other);
  b.Finalize;

  (* stop halfway *)
  a.Reset;
  rows := 0;
  WHILE (rows < 150) & a.Step() DO INC(rows) END;
  a.Reset;
  rows := 0; sum := 0;
  WHILE a.Step() DO INC(rows); INC(sum, a.ColumnInt(0)) END;
  ShowSum("reset halfway, then all", rows, sum);
  a.Reset;
  rows := 0;
  WHILE (rows < 150) & a.Step() DO INC(rows) END;
  a.Finalize;
  Check("finalized halfway, then a count", Count() >= 0);
  Check("Exec of a long result",
    conn.Exec("WITH RECURSIVE series (i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM series WHERE i < 250) SELECT i FROM series"))
END TestLong;


(* ---- Many statements ---- *)

PROCEDURE TestMany;
  VAR s: Db.Statement; i: INTEGER; ok: BOOLEAN;
BEGIN
  Heading("Many statements");
  ok := TRUE; i := 0;
  WHILE ok & (i < 1000) DO
    ok := conn.Prepare("SELECT COUNT(*) FROM podb_conformance WHERE id > ?", s);
    IF ok THEN
      s.BindInt(1, i);
      ok := s.Step() & (conn.err = Db.noError);
      s.Finalize
    END;
    INC(i)
  END;
  Check("1000 statements prepared and finalized", ok)
END TestMany;


BEGIN
  IF Args.argc > 1 THEN Args.Get(1, url) ELSE url := "sqlite::memory:" END;
  IF ~Db.Open(url, conn) THEN
    Out.String("cannot open the database: "); Out.String(Db.lastError); Out.Ln;
    HALT(1)
  END;
  Setup("DROP TABLE IF EXISTS podb_conformance");
  Setup("CREATE TABLE podb_conformance (id INTEGER PRIMARY KEY, name TEXT, n BIGINT, r DOUBLE PRECISION)");
  TestBasics;
  TestColumns;
  TestRoundTrips;
  TestNull;
  TestText;
  TestTransactions;
  TestErrors;
  TestReuse;
  TestReturning;
  TestChanges;
  TestBlobs;
  TestLong;
  TestMany;
  Setup("DROP TABLE podb_conformance");
  conn.Close
END Conformance.
