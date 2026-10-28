MODULE DbCStrings;
(* Helpers the poDB drivers share for the 0X-terminated strings that C
   functions return: their length, and copying one into an Oberon array.
   A NIL pointer is taken for the empty string. *)

IMPORT SYSTEM;

PROCEDURE ["C", "strlen"] StringLength (s: SYSTEM.ADDRESS): SYSTEM.ADDRESS;

PROCEDURE Length* (p: SYSTEM.ADDRESS): SYSTEM.ADDRESS;
(* Number of characters in the C string at p, not counting the 0X. *)
BEGIN
  IF p = 0 THEN RETURN 0 ELSE RETURN StringLength(p) END
END Length;

PROCEDURE Fits* (p: SYSTEM.ADDRESS; VAR out: ARRAY OF CHAR): BOOLEAN;
(* TRUE if the C string at p, with its 0X, fits in out without truncation. *)
BEGIN
  RETURN Length(p) < LEN(out)
END Fits;

PROCEDURE Copy* (p: SYSTEM.ADDRESS; VAR out: ARRAY OF CHAR);
(* Copy the C string at p into out, truncated to fit; out always ends with
   0X. *)
  VAR n: SYSTEM.ADDRESS;
BEGIN
  n := Length(p);
  IF n > LEN(out) - 1 THEN n := LEN(out) - 1 END;
  IF n > 0 THEN SYSTEM.MOVE(p, SYSTEM.ADR(out[0]), n) END;
  out[n] := 0X
END Copy;

END DbCStrings.
