MODULE SmokeSqlite;
(* Phase 0's smoke test: calls sqlite3_libversion through ["C"], linked
   with -link -lsqlite3, and prints the version string it returns.  It
   shows that external procedures, -link and copying a C string into an
   Oberon array all work. *)

  IMPORT SYSTEM, Out;

  VAR version: ARRAY 64 OF CHAR;

  PROCEDURE ["C", "sqlite3_libversion"] LibraryVersion (): SYSTEM.ADDRESS;

  PROCEDURE CopyCString (p: SYSTEM.ADDRESS; VAR out: ARRAY OF CHAR);
  (* Copy the 0X-terminated C string at p into out, truncating to fit. *)
    VAR i: LONGINT; c: CHAR;
  BEGIN
    i := 0;
    IF p # 0 THEN
      SYSTEM.GET(p, c);
      WHILE (c # 0X) & (i < LEN(out) - 1) DO
        out[i] := c; INC(i);
        SYSTEM.GET(p + i, c)
      END
    END;
    out[i] := 0X
  END CopyCString;

BEGIN
  CopyCString(LibraryVersion(), version);
  Out.String(version); Out.Ln
END SmokeSqlite.
