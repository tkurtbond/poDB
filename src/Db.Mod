MODULE Db;
(* Database-independent SQL interface for Oberon-2.

   Application code imports only Db (plus the driver modules it wants linked
   in).  A driver (DbSqlite, DbPostgres, ...) extends Driver, Connection and
   Statement, overrides the abstract procedures, and registers itself under a
   URL scheme from its module body.  Db.Open then picks the driver from the
   scheme of the connection URL:

       sqlite:///path/to/file.db        sqlite:///:memory:
       postgres://user:pw@host:5432/dbname

   Placeholders in SQL text come in two styles; a statement uses one or the
   other, never both:
       positional   ... WHERE age >= ? AND city = ?     bind with BindInt(1, ..)
       named        ... WHERE age >= :min AND city = :c bind with BindIntByName("min", ..)
   A driver's Prepare passes the SQL through Db.Translate, which rewrites
   every placeholder to the numbered form the database wants ("?" gives ?1,
   ?2 ... for SQLite; "$" gives $1, $2 ... for PostgreSQL) and records the
   parameter names in s.params.  A name that occurs several times shares one
   parameter number.  The ByName binders are written once here, on top of the
   numbered binders, so drivers implement only the numbered ones.

   Result columns can be read by 0-based number (ColumnInt(0)) or by name
   (ColumnIntByName("id")).  Names are matched case-insensitively, because
   PostgreSQL folds unquoted names to lower case and SQLite keeps them as
   written; with duplicate names (joins) the first match wins.  The ByName
   readers are written once here, on top of ColumnCount and ColumnName, which
   each driver implements.

   Conventions every driver must follow:
     - Parameter indexes are 1-based (they match ?1 / $1 in the SQL text);
       result column indexes are 0-based.
     - Each driver operation first sets c.err := noError; on failure it sets
       c.err to one of the err* codes and c.msg to the database's message
       (Db.SetError does both).
     - Finalize and Close leave c.err as it is, so that Exec can report an
       error from Step, and a loop's error survives finalizing its statement.
     - Prepare calls Db.Translate and stores the result in s.params, and sets
       s.conn := c.
     - Step returns TRUE when a row is available, FALSE when the statement is
       done OR failed; callers check c.err after the loop.
     - ColumnText copies into the caller's buffer and truncates if too small.
*)

CONST
  noError* = 0;
  errConnect* = 1;   (* could not open the database *)
  errSql* = 2;       (* prepare/execute failed *)
  errRange* = 3;     (* bad parameter index, unknown parameter name *)
  errDriver* = 4;    (* no driver for scheme, bad URL *)

  typeNull* = 0;
  typeInt* = 1;
  typeReal* = 2;
  typeText* = 3;

  maxParams = 64;
  maxName = 32;
  maxColumnName = 128;   (* PostgreSQL's limit is 63 bytes *)

TYPE
  Message* = ARRAY 256 OF CHAR;

  Params* = RECORD
    n*: INTEGER;      (* number of distinct parameters *)
    named*: BOOLEAN;  (* TRUE if the SQL used :name placeholders *)
    name*: ARRAY maxParams OF ARRAY maxName OF CHAR   (* name[i] belongs to parameter i+1 *)
  END;

  Connection* = POINTER TO ConnectionDesc;
  Statement* = POINTER TO StatementDesc;
  Driver* = POINTER TO DriverDesc;

  ConnectionDesc* = RECORD
    err*: INTEGER;
    msg*: Message
  END;

  StatementDesc* = RECORD
    conn*: Connection;
    params*: Params
  END;

  DriverDesc* = RECORD
    scheme*: ARRAY 32 OF CHAR;
    next: Driver
  END;

VAR
  lastError*: Message;   (* set when Open fails *)
  drivers: Driver;


PROCEDURE SetError* (c: Connection; code: INTEGER; msg: ARRAY OF CHAR);
BEGIN
  c.err := code;
  COPY(msg, c.msg)
END SetError;


(* ---- Placeholder translation ---- *)

PROCEDURE IsNameStart (c: CHAR): BOOLEAN;
BEGIN
  RETURN ((c >= "a") & (c <= "z")) OR ((c >= "A") & (c <= "Z")) OR (c = "_")
END IsNameStart;

PROCEDURE IsNameChar (c: CHAR): BOOLEAN;
BEGIN
  RETURN IsNameStart(c) OR ((c >= "0") & (c <= "9"))
END IsNameChar;

PROCEDURE IndexOf* (VAR p: Params; name: ARRAY OF CHAR): INTEGER;
(* 1-based parameter number for name, or 0 if there is none. *)
  VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE (i < p.n) & (p.name[i] # name) DO INC(i) END;
  IF i < p.n THEN RETURN i + 1 ELSE RETURN 0 END
END IndexOf;

PROCEDURE Put (VAR out: ARRAY OF CHAR; VAR o: LONGINT; c: CHAR; VAR ok: BOOLEAN);
BEGIN
  IF ok & (o < LEN(out) - 1) THEN out[o] := c; INC(o) ELSE ok := FALSE END
END Put;

PROCEDURE PutIndex (VAR out: ARRAY OF CHAR; VAR o: LONGINT; prefix: CHAR; n: INTEGER;
                    VAR ok: BOOLEAN);
  VAR digits: ARRAY 8 OF CHAR; k: INTEGER;
BEGIN
  Put(out, o, prefix, ok);
  k := 0;
  REPEAT
    digits[k] := CHR(ORD("0") + n MOD 10);
    n := n DIV 10;
    INC(k)
  UNTIL n = 0;
  WHILE k > 0 DO DEC(k); Put(out, o, digits[k], ok) END
END PutIndex;

PROCEDURE Translate* (sql: ARRAY OF CHAR; prefix: CHAR; VAR out: ARRAY OF CHAR;
                      VAR p: Params): BOOLEAN;
(* Rewrite the placeholders in sql into prefix+number (?1, ?2 ... or $1, $2 ...)
   and fill p.  Returns FALSE if the output buffer is too small, there are more
   than 64 parameters or a name is longer than 31 characters, or ? and :name
   are mixed.  Text inside '...' and "..." and inside comments is copied
   unchanged, and :: (a PostgreSQL cast) is not taken for a parameter.
   Not handled: PostgreSQL dollar-quoted strings; PostgreSQL operators that
   contain a question mark. *)
  VAR i, o: LONGINT; k, idx: INTEGER; c, q: CHAR; name: ARRAY maxName OF CHAR;
      ok, named, positional: BOOLEAN;
BEGIN
  p.n := 0; p.named := FALSE;
  i := 0; o := 0; ok := TRUE; named := FALSE; positional := FALSE;
  WHILE ok & (i < LEN(sql)) & (sql[i] # 0X) DO
    c := sql[i];
    IF (c = "'") OR (c = 22X) THEN
      (* quoted string or identifier: copy through the closing quote *)
      q := c;
      Put(out, o, c, ok); INC(i);
      WHILE ok & (i < LEN(sql)) & (sql[i] # 0X) & (sql[i] # q) DO
        Put(out, o, sql[i], ok); INC(i)
      END;
      IF (i < LEN(sql)) & (sql[i] = q) THEN Put(out, o, q, ok); INC(i) END
    ELSIF (c = "-") & (i + 1 < LEN(sql)) & (sql[i + 1] = "-") THEN
      (* line comment *)
      WHILE ok & (i < LEN(sql)) & (sql[i] # 0X) & (sql[i] # 0AX) DO
        Put(out, o, sql[i], ok); INC(i)
      END
    ELSIF (c = "/") & (i + 1 < LEN(sql)) & (sql[i + 1] = "*") THEN
      (* block comment *)
      Put(out, o, "/", ok); Put(out, o, "*", ok); INC(i, 2);
      WHILE ok & (i + 1 < LEN(sql)) & (sql[i] # 0X) & ~((sql[i] = "*") & (sql[i + 1] = "/")) DO
        Put(out, o, sql[i], ok); INC(i)
      END;
      IF (i + 1 < LEN(sql)) & (sql[i] = "*") THEN
        Put(out, o, "*", ok); Put(out, o, "/", ok); INC(i, 2)
      END
    ELSIF (c = ":") & (i + 1 < LEN(sql)) & IsNameStart(sql[i + 1])
          & ((i = 0) OR (sql[i - 1] # ":")) THEN
      (* named parameter *)
      INC(i); k := 0;
      WHILE (i < LEN(sql)) & IsNameChar(sql[i]) & (k < maxName - 1) DO
        name[k] := sql[i]; INC(k); INC(i)
      END;
      name[k] := 0X;
      IF (i < LEN(sql)) & IsNameChar(sql[i]) THEN ok := FALSE END;   (* name too long *)
      IF ok THEN
        idx := IndexOf(p, name);
        IF idx = 0 THEN
          IF p.n >= maxParams THEN ok := FALSE
          ELSE COPY(name, p.name[p.n]); INC(p.n); idx := p.n
          END
        END
      END;
      named := TRUE;
      IF ok THEN PutIndex(out, o, prefix, idx, ok) END
    ELSIF c = "?" THEN
      (* positional parameter: numbered in order of appearance *)
      IF p.n >= maxParams THEN ok := FALSE
      ELSE p.name[p.n][0] := 0X; INC(p.n); PutIndex(out, o, prefix, p.n, ok)
      END;
      positional := TRUE;
      INC(i)
    ELSE
      Put(out, o, c, ok); INC(i)
    END
  END;
  IF named & positional THEN ok := FALSE END;
  IF ok THEN out[o] := 0X END;
  p.named := named;
  RETURN ok
END Translate;


(* ---- Driver: implemented by each backend ---- *)

PROCEDURE (d: Driver) Open* (url: ARRAY OF CHAR): Connection;
(* Returns NIL on failure, after setting Db.lastError. *)
BEGIN
  RETURN NIL
END Open;

PROCEDURE Register* (d: Driver; scheme: ARRAY OF CHAR);
BEGIN
  COPY(scheme, d.scheme);
  d.next := drivers;
  drivers := d
END Register;


(* ---- Connection ---- *)

PROCEDURE ^ (s: Statement) Step* (): BOOLEAN;
PROCEDURE ^ (s: Statement) Finalize* ;

PROCEDURE (c: Connection) Close* ;
(* abstract *)
END Close;

PROCEDURE (c: Connection) Prepare* (sql: ARRAY OF CHAR; VAR s: Statement): BOOLEAN;
(* abstract: TRUE on success *)
BEGIN
  s := NIL;
  RETURN FALSE
END Prepare;

PROCEDURE (c: Connection) Exec* (sql: ARRAY OF CHAR): BOOLEAN;
(* Run one statement that needs no parameters and ignore any result row. *)
  VAR s: Statement; row: BOOLEAN;
BEGIN
  IF ~c.Prepare(sql, s) THEN RETURN FALSE END;
  row := s.Step();
  s.Finalize;
  RETURN c.err = noError
END Exec;

PROCEDURE (c: Connection) Begin* (): BOOLEAN;
BEGIN
  RETURN c.Exec("BEGIN")
END Begin;

PROCEDURE (c: Connection) Commit* (): BOOLEAN;
BEGIN
  RETURN c.Exec("COMMIT")
END Commit;

PROCEDURE (c: Connection) Rollback* (): BOOLEAN;
BEGIN
  RETURN c.Exec("ROLLBACK")
END Rollback;


(* ---- Statement: numbered binding, implemented by drivers ---- *)

PROCEDURE (s: Statement) BindNull* (i: INTEGER);
END BindNull;

PROCEDURE (s: Statement) BindInt* (i: INTEGER; v: HUGEINT);
END BindInt;

PROCEDURE (s: Statement) BindReal* (i: INTEGER; v: LONGREAL);
END BindReal;

PROCEDURE (s: Statement) BindText* (i: INTEGER; v: ARRAY OF CHAR);
END BindText;


(* ---- Statement: binding by name, written once here ----
   An unknown name sets conn.err to errRange; check conn.err as usual. *)

PROCEDURE (s: Statement) ParamIndex* (name: ARRAY OF CHAR): INTEGER;
(* 1-based parameter number for name, or 0 if the statement has no such name. *)
BEGIN
  RETURN IndexOf(s.params, name)
END ParamIndex;

PROCEDURE (s: Statement) BindNullByName* (name: ARRAY OF CHAR);
  VAR i: INTEGER;
BEGIN
  i := IndexOf(s.params, name);
  IF i = 0 THEN SetError(s.conn, errRange, "no such parameter name") ELSE s.BindNull(i) END
END BindNullByName;

PROCEDURE (s: Statement) BindIntByName* (name: ARRAY OF CHAR; v: HUGEINT);
  VAR i: INTEGER;
BEGIN
  i := IndexOf(s.params, name);
  IF i = 0 THEN SetError(s.conn, errRange, "no such parameter name") ELSE s.BindInt(i, v) END
END BindIntByName;

PROCEDURE (s: Statement) BindRealByName* (name: ARRAY OF CHAR; v: LONGREAL);
  VAR i: INTEGER;
BEGIN
  i := IndexOf(s.params, name);
  IF i = 0 THEN SetError(s.conn, errRange, "no such parameter name") ELSE s.BindReal(i, v) END
END BindRealByName;

PROCEDURE (s: Statement) BindTextByName* (name: ARRAY OF CHAR; v: ARRAY OF CHAR);
  VAR i: INTEGER;
BEGIN
  i := IndexOf(s.params, name);
  IF i = 0 THEN SetError(s.conn, errRange, "no such parameter name") ELSE s.BindText(i, v) END
END BindTextByName;


(* ---- Statement: stepping and results, implemented by drivers ---- *)

PROCEDURE (s: Statement) Step* (): BOOLEAN;
BEGIN
  RETURN FALSE
END Step;

PROCEDURE (s: Statement) Reset* ;
(* Rewind so the statement can be bound and stepped again. *)
END Reset;

PROCEDURE (s: Statement) Finalize* ;
END Finalize;

PROCEDURE (s: Statement) ColumnCount* (): INTEGER;
BEGIN
  RETURN 0
END ColumnCount;

PROCEDURE (s: Statement) ColumnName* (i: INTEGER; VAR out: ARRAY OF CHAR);
(* Name of result column i (0-based), truncated to fit out. *)
BEGIN
  out[0] := 0X
END ColumnName;

PROCEDURE (s: Statement) ColumnType* (i: INTEGER): INTEGER;
BEGIN
  RETURN typeNull
END ColumnType;

PROCEDURE (s: Statement) ColumnInt* (i: INTEGER): HUGEINT;
BEGIN
  RETURN 0
END ColumnInt;

PROCEDURE (s: Statement) ColumnReal* (i: INTEGER): LONGREAL;
BEGIN
  RETURN 0
END ColumnReal;

PROCEDURE (s: Statement) ColumnText* (i: INTEGER; VAR out: ARRAY OF CHAR);
BEGIN
  out[0] := 0X
END ColumnText;


(* ---- Statement: reading columns by name, written once here ----
   An unknown name sets conn.err to errRange and the reader returns 0 or an
   empty string; check conn.err as usual.  Each call searches the column
   names, so for large loops look the index up once with ColumnIndex and use
   the numbered readers. *)

PROCEDURE Lower (c: CHAR): CHAR;
BEGIN
  IF (c >= "A") & (c <= "Z") THEN RETURN CHR(ORD(c) + 32) ELSE RETURN c END
END Lower;

PROCEDURE SameName (a, b: ARRAY OF CHAR): BOOLEAN;
(* case-insensitive comparison of two zero-terminated strings *)
  VAR i: LONGINT;
BEGIN
  i := 0;
  WHILE (i < LEN(a)) & (i < LEN(b)) & (a[i] # 0X) & (Lower(a[i]) = Lower(b[i])) DO INC(i) END;
  RETURN (i < LEN(a)) & (i < LEN(b)) & (a[i] = 0X) & (b[i] = 0X)
END SameName;

PROCEDURE (s: Statement) ColumnIndex* (name: ARRAY OF CHAR): INTEGER;
(* 0-based column number for name (case-insensitive, first match), or -1. *)
  VAR i, n: INTEGER; cname: ARRAY maxColumnName OF CHAR;
BEGIN
  n := s.ColumnCount();
  i := 0;
  WHILE i < n DO
    s.ColumnName(i, cname);
    IF SameName(cname, name) THEN RETURN i END;
    INC(i)
  END;
  RETURN -1
END ColumnIndex;

PROCEDURE (s: Statement) ColumnTypeByName* (name: ARRAY OF CHAR): INTEGER;
  VAR i: INTEGER;
BEGIN
  i := s.ColumnIndex(name);
  IF i < 0 THEN SetError(s.conn, errRange, "no such column name"); RETURN typeNull END;
  RETURN s.ColumnType(i)
END ColumnTypeByName;

PROCEDURE (s: Statement) ColumnIntByName* (name: ARRAY OF CHAR): HUGEINT;
  VAR i: INTEGER;
BEGIN
  i := s.ColumnIndex(name);
  IF i < 0 THEN SetError(s.conn, errRange, "no such column name"); RETURN 0 END;
  RETURN s.ColumnInt(i)
END ColumnIntByName;

PROCEDURE (s: Statement) ColumnRealByName* (name: ARRAY OF CHAR): LONGREAL;
  VAR i: INTEGER;
BEGIN
  i := s.ColumnIndex(name);
  IF i < 0 THEN SetError(s.conn, errRange, "no such column name"); RETURN 0 END;
  RETURN s.ColumnReal(i)
END ColumnRealByName;

PROCEDURE (s: Statement) ColumnTextByName* (name: ARRAY OF CHAR; VAR out: ARRAY OF CHAR);
  VAR i: INTEGER;
BEGIN
  i := s.ColumnIndex(name);
  IF i < 0 THEN SetError(s.conn, errRange, "no such column name"); out[0] := 0X
  ELSE s.ColumnText(i, out)
  END
END ColumnTextByName;


(* ---- Opening ---- *)

PROCEDURE Open* (url: ARRAY OF CHAR; VAR conn: Connection): BOOLEAN;
(* Open a connection with the driver registered for url's scheme.  On
   failure conn is NIL and lastError says why; on success lastError is "". *)
  VAR i: LONGINT; scheme: ARRAY 32 OF CHAR; d: Driver;
BEGIN
  conn := NIL;
  lastError[0] := 0X;
  i := 0;
  WHILE (i < LEN(url)) & (url[i] # 0X) & (url[i] # ":") DO INC(i) END;
  IF (i >= LEN(url)) OR (url[i] # ":") OR (i = 0) THEN
    lastError := "Db.Open: connection URL has no scheme";
    RETURN FALSE
  ELSIF i >= LEN(scheme) THEN
    lastError := "Db.Open: no driver registered for scheme (is the driver module imported?)";
    RETURN FALSE
  END;
  scheme[i] := 0X;
  WHILE i > 0 DO DEC(i); scheme[i] := url[i] END;
  d := drivers;
  WHILE (d # NIL) & (d.scheme # scheme) DO d := d.next END;
  IF d = NIL THEN
    lastError := "Db.Open: no driver registered for scheme (is the driver module imported?)";
    RETURN FALSE
  END;
  conn := d.Open(url);
  IF (conn = NIL) & (lastError[0] = 0X) THEN
    lastError := "Db.Open: the driver could not open the connection"
  END;
  RETURN conn # NIL
END Open;

BEGIN
  drivers := NIL;
  lastError[0] := 0X
END Db.
