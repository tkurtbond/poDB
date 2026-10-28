/* DbPostgres's part in C: what Oberon must not call itself because the C
   functions are variadic (snprintf) or take a callback (the notice
   processor).  Numbers travel to and from PostgreSQL as text (decision D6). */

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <libpq-fe.h>

/* Write v in decimal to out, which holds size bytes. */
void podb_format_int(long long v, char *out, size_t size)
{
  snprintf(out, size, "%lld", v);
}

/* Write v to out, which holds size bytes, with enough digits (17) that
   reading it back gives v exactly. */
void podb_format_real(double v, char *out, size_t size)
{
  snprintf(out, size, "%.17g", v);
}

/* Parse all of s as an integer into *v and return 1.  A real number in
   range is truncated toward zero, as SQLite does.  Anything else sets *v to
   0 and returns 0. */
int podb_parse_int(const char *s, long long *v)
{
  char *end;
  long long n;
  double d;

  errno = 0;
  n = strtoll(s, &end, 10);
  if (end != s && *end == '\0' && errno == 0) {
    *v = n;
    return 1;
  }
  d = strtod(s, &end);
  if (end != s && *end == '\0'
      && d >= -9223372036854775808.0 && d < 9223372036854775808.0) {
    *v = (long long) d;
    return 1;
  }
  *v = 0;
  return 0;
}

/* Parse all of s as a real number into *v and return 1, or set *v to 0 and
   return 0. */
int podb_parse_real(const char *s, double *v)
{
  char *end;
  double d = strtod(s, &end);

  if (end != s && *end == '\0') {
    *v = d;
    return 1;
  }
  *v = 0;
  return 0;
}

static void ignore_notice(void *arg, const char *message)
{
  (void) arg;
  (void) message;
}

/* Stop libpq printing the server's notices (such as DROP TABLE IF EXISTS's
   "does not exist, skipping") on standard error. */
void podb_ignore_notices(PGconn *conn)
{
  PQsetNoticeProcessor(conn, ignore_notice, NULL);
}
