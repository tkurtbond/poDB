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
     - ColumnText copies into the caller's buffer and truncates if too small;
       ColumnBlob does too, and returns the value's whole length.
     - Changes is the number of rows the statement's last run inserted,
       updated or deleted, once Step has returned FALSE; Reset sets it to 0.
       The connection's Changes is the Changes of the last statement whose
       Step returned FALSE at the end of its run, or 0 if that run failed.

   Booleans, dates and time stamps have no type code of their own.  They
   are bound and read by the procedures in the section "Booleans, dates and
   times", written once here on top of the integer and text procedures.
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
  typeBlob* = 4;

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

  DateTime* = RECORD
    year*, month*, day*: INTEGER;      (* 1 .. 9999, 1 .. 12, 1 .. 31 *)
    hour*, minute*, second*: INTEGER;  (* 0 .. 23, 0 .. 59, 0 .. 59 *)
    microsecond*: LONGINT              (* 0 .. 999999 *)
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

PROCEDURE DollarTag (VAR sql: ARRAY OF CHAR; i: LONGINT; VAR tag: ARRAY OF CHAR;
                     VAR ok: BOOLEAN): BOOLEAN;
(* TRUE if the opening delimiter of a dollar-quoted string, $$ or $name$,
   starts at sql[i], and then tag is the delimiter.  A name too long for tag
   sets ok to FALSE. *)
  VAR k: LONGINT; tooLong: BOOLEAN;
BEGIN
  tag[0] := "$"; k := 1; INC(i); tooLong := FALSE;
  IF (i < LEN(sql)) & IsNameStart(sql[i]) THEN
    WHILE (i < LEN(sql)) & IsNameChar(sql[i]) DO
      IF k < LEN(tag) - 2 THEN tag[k] := sql[i]; INC(k) ELSE tooLong := TRUE END;
      INC(i)
    END
  END;
  IF (i < LEN(sql)) & (sql[i] = "$") THEN
    tag[k] := "$"; tag[k + 1] := 0X;
    IF tooLong THEN ok := FALSE END;
    RETURN TRUE
  END;
  RETURN FALSE
END DollarTag;

PROCEDURE At (VAR sql: ARRAY OF CHAR; i: LONGINT; VAR tag: ARRAY OF CHAR): BOOLEAN;
(* TRUE if sql[i] starts with tag *)
  VAR k: LONGINT;
BEGIN
  k := 0;
  WHILE (tag[k] # 0X) & (i + k < LEN(sql)) & (sql[i + k] = tag[k]) DO INC(k) END;
  RETURN tag[k] = 0X
END At;

PROCEDURE PutTag (VAR out: ARRAY OF CHAR; VAR o, i: LONGINT; VAR tag: ARRAY OF CHAR;
                  VAR ok: BOOLEAN);
(* copy tag to out, and move i past it in the SQL *)
  VAR k: LONGINT;
BEGIN
  k := 0;
  WHILE tag[k] # 0X DO Put(out, o, tag[k], ok); INC(k); INC(i) END
END PutTag;

PROCEDURE Translate* (sql: ARRAY OF CHAR; prefix: CHAR; VAR out: ARRAY OF CHAR;
                      VAR p: Params): BOOLEAN;
(* Rewrite the placeholders in sql into prefix+number (?1, ?2 ... or $1, $2 ...)
   and fill p.  Returns FALSE if the output buffer is too small, there are more
   than 64 parameters or a name is longer than 31 characters, or ? and :name
   are mixed, or a dollar quote's tag is longer than 31 characters.  Text
   inside '...', "...", PostgreSQL's dollar-quoted strings ($$...$$,
   $tag$...$tag$) and comments is copied unchanged, and :: (a PostgreSQL
   cast) is not taken for a parameter.  Not handled: PostgreSQL operators
   that contain a question mark. *)
  VAR i, o: LONGINT; k, idx: INTEGER; c, q: CHAR; name: ARRAY maxName OF CHAR;
      tag: ARRAY maxName + 2 OF CHAR; ok, named, positional: BOOLEAN;
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
    ELSIF (c = "$") & ((i = 0) OR ~IsNameChar(sql[i - 1]) & (sql[i - 1] # "$"))
          & DollarTag(sql, i, tag, ok) THEN
      (* dollar-quoted string: copy through the closing tag; $1 and the $ in
         a name such as a$b are not openings *)
      PutTag(out, o, i, tag, ok);
      WHILE ok & (i < LEN(sql)) & (sql[i] # 0X) & ~At(sql, i, tag) DO
        Put(out, o, sql[i], ok); INC(i)
      END;
      IF At(sql, i, tag) THEN PutTag(out, o, i, tag, ok) END
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
(* Run one statement that needs no parameters, to its end, and ignore any
   result rows.  Then c.Changes() gives the rows it changed. *)
  VAR s: Statement;
BEGIN
  IF ~c.Prepare(sql, s) THEN RETURN FALSE END;
  WHILE s.Step() DO END;
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

PROCEDURE (c: Connection) Changes* (): HUGEINT;
(* abstract: the number of rows inserted, updated or deleted by the last
   statement whose Step returned FALSE at the end of its run, Exec's
   included; 0 if that run failed or changed no rows.  A statement that
   fails in Prepare does not run, so check Exec's result first. *)
BEGIN
  RETURN 0
END Changes;


(* ---- Statement: numbered binding, implemented by drivers ---- *)

PROCEDURE (s: Statement) BindNull* (i: INTEGER);
END BindNull;

PROCEDURE (s: Statement) BindInt* (i: INTEGER; v: HUGEINT);
END BindInt;

PROCEDURE (s: Statement) BindReal* (i: INTEGER; v: LONGREAL);
END BindReal;

PROCEDURE (s: Statement) BindText* (i: INTEGER; v: ARRAY OF CHAR);
END BindText;

PROCEDURE (s: Statement) BindBlob* (i: INTEGER; VAR v: ARRAY OF CHAR; n: LONGINT);
(* Bind the n bytes v[0] .. v[n-1], which may include 0X, as a BLOB (SQLite)
   or bytea (PostgreSQL).  n < 0 or n > LEN(v) sets errRange. *)
END BindBlob;


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

PROCEDURE (s: Statement) BindBlobByName* (name: ARRAY OF CHAR; VAR v: ARRAY OF CHAR; n: LONGINT);
  VAR i: INTEGER;
BEGIN
  i := IndexOf(s.params, name);
  IF i = 0 THEN SetError(s.conn, errRange, "no such parameter name") ELSE s.BindBlob(i, v, n) END
END BindBlobByName;


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

PROCEDURE (s: Statement) Changes* (): HUGEINT;
(* The number of rows the statement's last run inserted, updated or deleted,
   once Step has returned FALSE.  0 before then, after Reset, and for a
   statement that changes no rows. *)
BEGIN
  RETURN 0
END Changes;

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

PROCEDURE (s: Statement) ColumnBlob* (i: INTEGER; VAR out: ARRAY OF CHAR): LONGINT;
(* Copy as many of the value's bytes as fit into out, with no 0X added, and
   return the value's whole length in bytes: if that is more than LEN(out),
   the value was truncated.  NULL has length 0.  A value that is not a BLOB
   gives the bytes of its text form. *)
BEGIN
  RETURN 0
END ColumnBlob;

PROCEDURE (s: Statement) ColumnIsNull* (i: INTEGER): BOOLEAN;
(* TRUE if column i of the current row is NULL. *)
BEGIN
  RETURN s.ColumnType(i) = typeNull
END ColumnIsNull;


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

PROCEDURE (s: Statement) ColumnBlobByName* (name: ARRAY OF CHAR; VAR out: ARRAY OF CHAR): LONGINT;
  VAR i: INTEGER;
BEGIN
  i := s.ColumnIndex(name);
  IF i < 0 THEN SetError(s.conn, errRange, "no such column name"); RETURN 0 END;
  RETURN s.ColumnBlob(i, out)
END ColumnBlobByName;

PROCEDURE (s: Statement) ColumnIsNullByName* (name: ARRAY OF CHAR): BOOLEAN;
(* An unknown name counts as NULL, besides setting errRange. *)
  VAR i: INTEGER;
BEGIN
  i := s.ColumnIndex(name);
  IF i < 0 THEN SetError(s.conn, errRange, "no such column name"); RETURN TRUE END;
  RETURN s.ColumnIsNull(i)
END ColumnIsNullByName;


(* ---- Booleans, dates and times, written once here ----
   A boolean is bound as the integer 1 or 0.  SQLite stores that as it is,
   and PostgreSQL takes it for a boolean as well as for an integer.  It
   reads as TRUE for any value whose ColumnInt is not 0; the PostgreSQL
   driver reads a boolean as 1 or 0.

   A date or a time stamp is bound as ISO 8601 text: "2026-10-28", or
   "2026-10-28 14:30:00" with ".ffffff" after it if the microseconds are
   not 0.  SQLite stores the text, which sorts and compares as the dates
   do, and its date functions understand it.  PostgreSQL takes it for a
   date or a timestamp, and its driver asks for ISO output.  ColumnDateTime
   parses that form back, with "T" also allowed between the date and the
   time, and any number of digits after the decimal point (beyond six are
   dropped).  A value with a time zone, such as PostgreSQL's timestamptz
   gives, is not one it parses. *)

PROCEDURE DaysIn (year, month: INTEGER): INTEGER;
(* the number of days in month (1 .. 12) of year, in the Gregorian calendar *)
BEGIN
  IF month = 2 THEN
    IF (year MOD 4 = 0) & ((year MOD 100 # 0) OR (year MOD 400 = 0)) THEN RETURN 29 ELSE RETURN 28 END
  ELSIF (month = 4) OR (month = 6) OR (month = 9) OR (month = 11) THEN RETURN 30
  ELSE RETURN 31
  END
END DaysIn;

PROCEDURE ValidDate (VAR d: DateTime): BOOLEAN;
BEGIN
  RETURN (d.year >= 1) & (d.year <= 9999) & (d.month >= 1) & (d.month <= 12)
    & (d.day >= 1) & (d.day <= DaysIn(d.year, d.month))
END ValidDate;

PROCEDURE ValidTime (VAR d: DateTime): BOOLEAN;
BEGIN
  RETURN (d.hour >= 0) & (d.hour <= 23) & (d.minute >= 0) & (d.minute <= 59)
    & (d.second >= 0) & (d.second <= 59) & (d.microsecond >= 0) & (d.microsecond <= 999999)
END ValidTime;

PROCEDURE PutNumber (VAR out: ARRAY OF CHAR; VAR o: LONGINT; n: LONGINT; width: INTEGER);
(* n, which is not negative and has at most width digits, in width digits
   with leading zeros *)
  VAR k: INTEGER;
BEGIN
  FOR k := width - 1 TO 0 BY -1 DO
    out[o + k] := CHR(ORD("0") + n MOD 10); n := n DIV 10
  END;
  INC(o, width)
END PutNumber;

PROCEDURE FormatDateTime (VAR d: DateTime; withTime: BOOLEAN; VAR out: ARRAY OF CHAR);
(* d, which is valid, as ISO 8601 text; out has room for 27 characters *)
  VAR o: LONGINT;
BEGIN
  o := 0;
  PutNumber(out, o, d.year, 4); out[o] := "-"; INC(o);
  PutNumber(out, o, d.month, 2); out[o] := "-"; INC(o);
  PutNumber(out, o, d.day, 2);
  IF withTime THEN
    out[o] := " "; INC(o);
    PutNumber(out, o, d.hour, 2); out[o] := ":"; INC(o);
    PutNumber(out, o, d.minute, 2); out[o] := ":"; INC(o);
    PutNumber(out, o, d.second, 2);
    IF d.microsecond # 0 THEN out[o] := "."; INC(o); PutNumber(out, o, d.microsecond, 6) END
  END;
  out[o] := 0X
END FormatDateTime;

PROCEDURE IsDigit (c: CHAR): BOOLEAN;
BEGIN
  RETURN (c >= "0") & (c <= "9")
END IsDigit;

PROCEDURE Digits (VAR t: ARRAY OF CHAR; VAR i: LONGINT; width: INTEGER; VAR n: INTEGER): BOOLEAN;
(* Read exactly width (at most 4) digits of t from i into n. *)
  VAR k: INTEGER;
BEGIN
  n := 0;
  FOR k := 1 TO width DO
    IF ~IsDigit(t[i]) THEN RETURN FALSE END;
    n := n * 10 + (ORD(t[i]) - ORD("0")); INC(i)
  END;
  RETURN TRUE
END Digits;

PROCEDURE Separator (VAR t: ARRAY OF CHAR; VAR i: LONGINT; c: CHAR): BOOLEAN;
(* Skip t[i] if it is c. *)
BEGIN
  IF t[i] # c THEN RETURN FALSE END;
  INC(i);
  RETURN TRUE
END Separator;

PROCEDURE ParseDateTime (VAR t: ARRAY OF CHAR; VAR d: DateTime): BOOLEAN;
(* Parse t, 0X-terminated, as "YYYY-MM-DD", optionally followed by a space
   or "T" and "HH:MM", ":SS" and ".fff..."; TRUE if it is a valid date or
   time stamp. *)
  VAR i, scale: LONGINT;
BEGIN
  i := 0;
  IF ~Digits(t, i, 4, d.year) OR ~Separator(t, i, "-") OR ~Digits(t, i, 2, d.month)
     OR ~Separator(t, i, "-") OR ~Digits(t, i, 2, d.day) THEN
    RETURN FALSE
  END;
  IF t[i] # 0X THEN
    IF (t[i] # " ") & (t[i] # "T") THEN RETURN FALSE END;
    INC(i);
    IF ~Digits(t, i, 2, d.hour) OR ~Separator(t, i, ":") OR ~Digits(t, i, 2, d.minute) THEN
      RETURN FALSE
    END;
    IF t[i] = ":" THEN
      INC(i);
      IF ~Digits(t, i, 2, d.second) THEN RETURN FALSE END;
      IF t[i] = "." THEN
        INC(i);
        IF ~IsDigit(t[i]) THEN RETURN FALSE END;
        scale := 100000;
        WHILE IsDigit(t[i]) DO
          INC(d.microsecond, (ORD(t[i]) - ORD("0")) * scale); scale := scale DIV 10; INC(i)
        END
      END
    END
  END;
  RETURN (t[i] = 0X) & ValidDate(d) & ValidTime(d)
END ParseDateTime;

PROCEDURE ClearDateTime (VAR d: DateTime);
BEGIN
  d.year := 0; d.month := 0; d.day := 0;
  d.hour := 0; d.minute := 0; d.second := 0; d.microsecond := 0
END ClearDateTime;

PROCEDURE (s: Statement) BindBool* (i: INTEGER; v: BOOLEAN);
(* Bind v to parameter i (1-based), as 1 or 0. *)
BEGIN
  IF v THEN s.BindInt(i, 1) ELSE s.BindInt(i, 0) END
END BindBool;

PROCEDURE (s: Statement) BindDate* (i: INTEGER; d: DateTime);
(* Bind d's date to parameter i (1-based), as "YYYY-MM-DD"; d's time is
   ignored.  An invalid date sets errRange. *)
  VAR text: ARRAY 32 OF CHAR;
BEGIN
  IF ValidDate(d) THEN FormatDateTime(d, FALSE, text); s.BindText(i, text)
  ELSE SetError(s.conn, errRange, "not a valid date")
  END
END BindDate;

PROCEDURE (s: Statement) BindDateTime* (i: INTEGER; d: DateTime);
(* Bind d to parameter i (1-based), as "YYYY-MM-DD HH:MM:SS", with
   ".ffffff" if d.microsecond # 0.  An invalid date or time sets errRange. *)
  VAR text: ARRAY 32 OF CHAR;
BEGIN
  IF ValidDate(d) & ValidTime(d) THEN FormatDateTime(d, TRUE, text); s.BindText(i, text)
  ELSE SetError(s.conn, errRange, "not a valid date and time")
  END
END BindDateTime;

PROCEDURE (s: Statement) ColumnBool* (i: INTEGER): BOOLEAN;
(* TRUE if column i's value is not 0 as an integer; FALSE for NULL. *)
BEGIN
  RETURN s.ColumnInt(i) # 0
END ColumnBool;

PROCEDURE (s: Statement) ColumnDateTime* (i: INTEGER; VAR d: DateTime);
(* Parse column i's value, a date or a time stamp in ISO 8601 form, into d.
   A date alone gives a time of 00:00:00.  NULL gives all fields 0; so does
   any other value, which also sets errRange. *)
  VAR text: ARRAY 64 OF CHAR;
BEGIN
  ClearDateTime(d);
  IF s.ColumnType(i) # typeNull THEN
    s.ColumnText(i, text);
    IF ~ParseDateTime(text, d) THEN
      ClearDateTime(d);
      SetError(s.conn, errRange, "not a date or a time stamp")
    END
  END
END ColumnDateTime;

PROCEDURE (s: Statement) BindBoolByName* (name: ARRAY OF CHAR; v: BOOLEAN);
  VAR i: INTEGER;
BEGIN
  i := IndexOf(s.params, name);
  IF i = 0 THEN SetError(s.conn, errRange, "no such parameter name") ELSE s.BindBool(i, v) END
END BindBoolByName;

PROCEDURE (s: Statement) BindDateByName* (name: ARRAY OF CHAR; d: DateTime);
  VAR i: INTEGER;
BEGIN
  i := IndexOf(s.params, name);
  IF i = 0 THEN SetError(s.conn, errRange, "no such parameter name") ELSE s.BindDate(i, d) END
END BindDateByName;

PROCEDURE (s: Statement) BindDateTimeByName* (name: ARRAY OF CHAR; d: DateTime);
  VAR i: INTEGER;
BEGIN
  i := IndexOf(s.params, name);
  IF i = 0 THEN SetError(s.conn, errRange, "no such parameter name") ELSE s.BindDateTime(i, d) END
END BindDateTimeByName;

PROCEDURE (s: Statement) ColumnBoolByName* (name: ARRAY OF CHAR): BOOLEAN;
  VAR i: INTEGER;
BEGIN
  i := s.ColumnIndex(name);
  IF i < 0 THEN SetError(s.conn, errRange, "no such column name"); RETURN FALSE END;
  RETURN s.ColumnBool(i)
END ColumnBoolByName;

PROCEDURE (s: Statement) ColumnDateTimeByName* (name: ARRAY OF CHAR; VAR d: DateTime);
  VAR i: INTEGER;
BEGIN
  i := s.ColumnIndex(name);
  IF i < 0 THEN SetError(s.conn, errRange, "no such column name"); ClearDateTime(d)
  ELSE s.ColumnDateTime(i, d)
  END
END ColumnDateTimeByName;


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
