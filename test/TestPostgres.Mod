MODULE TestPostgres;
(* Tests of what only the PostgreSQL driver does, run with the test
   cluster's URL:

     TestPostgres 'postgres:///podb_test?host=/path/to/socket&user=podb'

   A query's rows arrive in chunks, so a query that fails partway gives the
   rows of the chunks before the error, then the error.  Were the whole
   result read at once, the error would come before any row.  The command
   tag that gives Changes is on the last chunk if it is partly filled, and
   on the result after the chunks if not, so both are tested.

   PrepareQuery's statements read through a cursor, which exists only in a
   transaction.  pg_cursors shows whether Reset, Finalize and the end of the
   rows close it. *)

IMPORT Db, Out, Args, DbPostgres;

VAR
  url: ARRAY 256 OF CHAR;
  conn: Db.Connection;

PROCEDURE FailPartway (label, sql: ARRAY OF CHAR);
(* Step through sql's rows and print how many there were and the error. *)
  VAR s: Db.Statement; rows: LONGINT;
BEGIN
  IF ~conn.Prepare(sql, s) THEN
    Out.String("prepare failed: "); Out.String(conn.msg); Out.Ln; HALT(1)
  END;
  rows := 0;
  WHILE s.Step() DO INC(rows) END;
  Out.String(label); Out.String(": rows="); Out.Int(rows, 0);
  Out.String(" err="); Out.Int(conn.err, 0); Out.Ln;
  s.Finalize
END FailPartway;

PROCEDURE ChangesReturning (rows: LONGINT);
(* Update rows rows with RETURNING, step through them, and print Changes. *)
  VAR s: Db.Statement; n: LONGINT;
BEGIN
  IF ~conn.Prepare("UPDATE podb_stream SET a = a + 1 WHERE id <= ? RETURNING id", s) THEN
    Out.String("prepare failed: "); Out.String(conn.msg); Out.Ln; HALT(1)
  END;
  s.BindInt(1, rows);
  n := 0;
  WHILE s.Step() DO INC(n) END;
  Out.String("UPDATE ... RETURNING of "); Out.Int(rows, 0); Out.String(" rows: rows=");
  Out.Int(n, 0); Out.String(" Changes="); Out.Int(s.Changes(), 0);
  Out.String(" err="); Out.Int(conn.err, 0); Out.Ln;
  s.Finalize
END ChangesReturning;

PROCEDURE Cursors (): HUGEINT;
(* The number of cursors open on the connection. *)
  VAR s: Db.Statement; n: HUGEINT;
BEGIN
  n := -1;
  IF conn.Prepare("SELECT COUNT(*) FROM pg_cursors WHERE name <> ''", s) THEN
    IF s.Step() THEN n := s.ColumnInt(0) END;
    s.Finalize
  END;
  RETURN n
END Cursors;

PROCEDURE Show (label: ARRAY OF CHAR; n: HUGEINT);
(* label, n and the connection's error *)
BEGIN
  Out.String(label); Out.String(": "); Out.Int(n, 0);
  Out.String(" err="); Out.Int(conn.err, 0); Out.Ln
END Show;

PROCEDURE Result (label: ARRAY OF CHAR; result: BOOLEAN);
(* label, TRUE or FALSE, and the connection's error *)
BEGIN
  Out.String(label); Out.String(": ");
  IF result THEN Out.String("TRUE") ELSE Out.String("FALSE") END;
  Out.String(" err="); Out.Int(conn.err, 0); Out.Ln
END Result;

PROCEDURE Query (sql: ARRAY OF CHAR; rows: LONGINT; VAR s: Db.Statement);
(* PrepareQuery sql, read rows at a time, and stop if that fails. *)
BEGIN
  IF ~conn.PrepareQuery(sql, rows, s) THEN
    Out.String("PrepareQuery failed: "); Out.String(conn.msg); Out.Ln; HALT(1)
  END
END Query;

PROCEDURE StepSome (s: Db.Statement; rows: LONGINT): LONGINT;
(* Step s at most rows times; the number of rows read. *)
  VAR n: LONGINT;
BEGIN
  n := 0;
  WHILE (n < rows) & s.Step() DO INC(n) END;
  RETURN n
END StepSome;

PROCEDURE TestCursors;
  VAR s: Db.Statement; ok: BOOLEAN;
BEGIN
  Query("SELECT n FROM generate_series(1, 30) AS n", 7, s);
  Show("a query outside a transaction", StepSome(s, 100));
  ok := conn.Begin();
  s.Reset;
  Show("in a transaction", StepSome(s, 10));
  Show("cursors open", Cursors());
  ok := conn.Commit();
  Show("after commit", StepSome(s, 100));
  s.Reset;
  ok := conn.Begin();
  Show("after Reset, in a new transaction", StepSome(s, 100));
  Show("cursors open at the end", Cursors());
  s.Reset;
  Show("again", StepSome(s, 10));
  s.Reset;
  Show("cursors open after Reset", Cursors());
  Show("again", StepSome(s, 10));
  s.Finalize;
  Show("cursors open after Finalize", Cursors());
  ok := conn.Commit();

  Result("PrepareQuery of an INSERT", conn.PrepareQuery("INSERT INTO podb_stream VALUES (1, 1)", 7, s));

  (* row 250 divides by zero, in the third batch of 100 *)
  ok := conn.Begin();
  Query("SELECT 1 / (250 - n) FROM generate_series(1, 300) AS n", 100, s);
  Show("an error in a cursor's third batch", StepSome(s, 1000));
  s.Finalize;
  Result("rollback after it", conn.Rollback())
END TestCursors;

BEGIN
  IF Args.argc > 1 THEN Args.Get(1, url) ELSE url := "postgres:///podb_test" END;
  IF ~Db.Open(url, conn) THEN
    Out.String("cannot open the database: "); Out.String(Db.lastError); Out.Ln;
    HALT(1)
  END;
  (* row 250 divides by zero; the chunks of rows 1 .. 200 come first *)
  FailPartway("an error at row 250", "SELECT 1 / (250 - n) FROM generate_series(1, 300) AS n");
  FailPartway("an error at row 1", "SELECT 1 / (1 - n) FROM generate_series(1, 300) AS n");
  IF ~conn.Exec("CREATE TEMPORARY TABLE podb_stream (id INTEGER, a INTEGER)")
     OR ~conn.Exec("INSERT INTO podb_stream SELECT n, 0 FROM generate_series(1, 300) AS n") THEN
    Out.String("setup failed: "); Out.String(conn.msg); Out.Ln; HALT(1)
  END;
  ChangesReturning(250);
  ChangesReturning(200);
  TestCursors;
  IF conn.Exec("SELECT 1") THEN Out.String("the connection still works") ELSE Out.String("FAIL: ") END;
  Out.Ln;
  conn.Close
END TestPostgres.
