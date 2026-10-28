#!/bin/sh
# Print the URL of the test database: $PODB_PG_URL if it is set, otherwise
# the database podb_test in the cluster that test/pg-start.sh runs.

if [ -n "$PODB_PG_URL" ]; then echo "$PODB_PG_URL"; exit; fi
top=$(cd "$(dirname "$0")/.." && pwd)
sock=$top/build/pgsock
if [ -f "$top/build/pgsock-dir" ]; then sock=$(cat "$top/build/pgsock-dir"); fi
echo "postgres:///podb_test?host=$sock&user=podb"
