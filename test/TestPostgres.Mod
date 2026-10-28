MODULE TestPostgres;
(* Tests of what only the PostgreSQL driver does, run with the test
   cluster's URL:

     TestPostgres 'postgres:///podb_test?host=/path/to/socket&user=podb'

   A query's rows arrive in chunks, so a query that fails partway gives the
   rows of the chunks before the error, then the error.  Were the whole
   result read at once, the error would come before any row.  The command
   tag that gives Changes is on the last chunk if it is partly filled, and
   on the result after the chunks if not, so both are tested. *)

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
  IF conn.Exec("SELECT 1") THEN Out.String("the connection still works") ELSE Out.String("FAIL: ") END;
  Out.Ln;
  conn.Close
END TestPostgres.
