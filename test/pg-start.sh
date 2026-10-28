#!/bin/sh
# Start the throwaway PostgreSQL cluster the tests use, making it first if
# it does not exist.  It lives in build/pgdata, is owned by whoever runs
# this, listens only on a Unix socket (no TCP) and trusts every local user.
# It is never the system's PostgreSQL service.  The database is podb_test,
# the user podb.
#
# A socket's path is limited to 107 bytes.  If build/pgsock is too deep for
# that, the socket goes in a short directory under /tmp instead, and
# build/pgsock-dir names it.  test/pg-url.sh prints the URL either way.

set -e
top=$(cd "$(dirname "$0")/.." && pwd)
data=$top/build/pgdata
sock=$top/build/pgsock

if [ $(printf '%s/.s.PGSQL.5432' "$sock" | wc -c) -gt 107 ]; then
  if [ -f "$top/build/pgsock-dir" ]; then sock=$(cat "$top/build/pgsock-dir")
  else sock=$(mktemp -d /tmp/podb-XXXXXX)
  fi
  echo "$sock" > "$top/build/pgsock-dir"
fi
mkdir -p "$sock"

if [ ! -f "$data/PG_VERSION" ]; then
  mkdir -p "$top/build"
  initdb -A trust -U podb -D "$data" > "$top/build/initdb.log"
fi

if ! pg_ctl -D "$data" status > /dev/null 2>&1; then
  pg_ctl -D "$data" -l "$top/build/pg.log" -w \
    -o "-c listen_addresses='' -k $sock" start > /dev/null
fi

if ! psql -h "$sock" -U podb -d postgres -tAc \
     "SELECT 1 FROM pg_database WHERE datname = 'podb_test'" | grep -q 1; then
  createdb -h "$sock" -U podb podb_test
fi
