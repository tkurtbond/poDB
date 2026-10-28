MODULE DbDemo;
(* Uses only the Db interface.  To move from SQLite to PostgreSQL, change the
   URL below (and import DbPostgres instead of / as well as DbSqlite).
   Assumes an Oakwood-style Out module; adjust to poc's runtime modules. *)

IMPORT Db, Out, DbSqlite;   (* DbSqlite is imported so its driver registers itself *)

CONST
  url = "sqlite:///demo.db";
  (* url = "postgres://demo:secret@localhost:5432/demo"; *)

VAR
  conn: Db.Connection;
  st: Db.Statement;
  name: ARRAY 64 OF CHAR;

PROCEDURE Fail (what: ARRAY OF CHAR);
BEGIN
  Out.String(what); Out.String(": "); Out.String(conn.msg); Out.Ln;
  HALT(1)
END Fail;

PROCEDURE AddPerson (id: LONGINT; name: ARRAY OF CHAR; age: LONGINT);
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
  IF ~Db.Open(url, conn) THEN
    Out.String(Db.lastError); Out.Ln; HALT(1)
  END;

  IF ~conn.Exec("CREATE TABLE IF NOT EXISTS person (id INTEGER PRIMARY KEY, name TEXT NOT NULL, age INTEGER)") THEN
    Fail("create table")
  END;

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
    Out.Int(SHORT(st.ColumnIntByName("id")), 0); Out.String("  "); Out.String(name); Out.Ln
  END;
  IF conn.err # Db.noError THEN Fail("select") END;
  st.Finalize;

  conn.Close
END DbDemo.
