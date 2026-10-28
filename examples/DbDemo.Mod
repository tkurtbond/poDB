MODULE DbDemo;
(* Uses only the Db interface.  To move from SQLite to PostgreSQL, change the
   URL below.  A program that uses only one database imports only its
   driver; this one imports both.  A URL given on the command line replaces
   the default:

     DbDemo sqlite::memory:
     DbDemo postgres://user@host/dbname *)

IMPORT Db, Out, Args, DbSqlite, DbPostgres;   (* imported so that their drivers register themselves *)

CONST
  defaultUrl = "sqlite:demo.db";
  (* defaultUrl = "postgres://demo:secret@localhost:5432/demo"; *)

VAR
  url: ARRAY 256 OF CHAR;
  conn: Db.Connection;
  st: Db.Statement;
  name: ARRAY 64 OF CHAR;

PROCEDURE Fail (what: ARRAY OF CHAR);
BEGIN
  Out.String(what); Out.String(": "); Out.String(conn.msg); Out.Ln;
  HALT(1)
END Fail;

PROCEDURE AddPerson (id: HUGEINT; name: ARRAY OF CHAR; age: HUGEINT);
(* named parameters *)
  VAR s: Db.Statement; row: BOOLEAN;
BEGIN
  IF ~conn.Prepare("INSERT INTO person (id, name, age) VALUES (:id, :name, :age)", s) THEN
    Fail("prepare insert")
  END;
  s.BindIntByName("id", id);
  s.BindTextByName("name", name);
  s.BindIntByName("age", age);
  IF conn.err # Db.noError THEN Fail("bind") END;
  row := s.Step();
  s.Finalize;
  IF conn.err # Db.noError THEN Fail("insert") END
END AddPerson;

BEGIN
  IF Args.argc > 1 THEN Args.Get(1, url) ELSE url := defaultUrl END;
  IF ~Db.Open(url, conn) THEN
    Out.String(Db.lastError); Out.Ln; HALT(1)
  END;

  IF ~conn.Exec("CREATE TABLE IF NOT EXISTS person (id INTEGER PRIMARY KEY, name TEXT NOT NULL, age INTEGER)") THEN
    Fail("create table")
  END;
  (* so that a second run against the same file starts from the same rows *)
  IF ~conn.Exec("DELETE FROM person") THEN Fail("delete") END;

  IF ~conn.Begin() THEN Fail("begin") END;
  AddPerson(1, "Ada", 36);
  AddPerson(2, "Niklaus", 90);
  IF ~conn.Commit() THEN Fail("commit") END;

  (* positional parameters work too; do not mix ? and :name in one statement *)
  IF ~conn.Prepare("SELECT id, name FROM person WHERE age >= ? ORDER BY id", st) THEN
    Fail("prepare select")
  END;
  st.BindInt(1, 40);
  WHILE st.Step() DO
    (* by name; by number this would be st.ColumnInt(0) and st.ColumnText(1, name) *)
    st.ColumnTextByName("name", name);
    Out.Int(st.ColumnIntByName("id"), 0); Out.String("  "); Out.String(name); Out.Ln
  END;
  IF conn.err # Db.noError THEN Fail("select") END;
  st.Finalize;

  conn.Close
END DbDemo.
