#!/bin/sh
# Stop the test cluster that test/pg-start.sh started, if it is running.

set -e
top=$(cd "$(dirname "$0")/.." && pwd)
data=$top/build/pgdata

if [ -f "$data/PG_VERSION" ] && pg_ctl -D "$data" status > /dev/null 2>&1; then
  pg_ctl -D "$data" -w stop > /dev/null
fi
