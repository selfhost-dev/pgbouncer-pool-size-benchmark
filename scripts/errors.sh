#!/bin/bash
set -u
: "${PG_HOST:?set PG_HOST first (see README)}"
: "${PGB_HOST:?set PGB_HOST first (see README)}"
WORKDIR=${WORKDIR:-$HOME/pgb}
cd "$WORKDIR"
echo "=== query_wait_timeout [selfrun, leakdemo pool_size=1, query_wait_timeout=5] ==="
psql -h "${PGB_HOST}" -p 6432 -U admin -d pgbouncer -qc "SET query_wait_timeout = 5"
psql -h "${PGB_HOST}" -p 6432 -U admin -d leakdemo -Atc "select pg_sleep(12)" >/dev/null &
sleep 1
( for i in 1 2 3 4; do psql -h "${PGB_HOST}" -p 6432 -U admin -d pgbouncer -Atc "SHOW POOLS" | grep '^leakdemo|' | awk -F'|' '{print "  SHOW POOLS leakdemo: cl_active="$3" cl_waiting="$4" sv_active="$7" maxwait="$14"s"}'; sleep 1; done ) &
/usr/bin/time -f "  client B gave up after %e s" psql -h "${PGB_HOST}" -p 6432 -U admin -d leakdemo -Atc "select 1" 2>&1 | sed 's/^/  /'
wait
psql -h "${PGB_HOST}" -p 6432 -U admin -d pgbouncer -qc "SET query_wait_timeout = 120"

echo "=== wrong password [managed 6432] ==="
PGPASSFILE=/dev/null PGPASSWORD=wrong psql "host=${PG_HOST} port=6432 user=admin dbname=postgres sslmode=disable" -c "select 1" 2>&1 | sed 's/^/  /'
echo "=== md5-only client [managed 6432] ==="
psql "host=${PG_HOST} port=6432 user=admin dbname=postgres sslmode=disable require_auth=md5" -c "select 1" 2>&1 | sed 's/^/  /'
echo "=== unknown user [managed 6432] ==="
PGPASSFILE=/dev/null PGPASSWORD=x psql "host=${PG_HOST} port=6432 user=nosuchuser dbname=postgres sslmode=disable" -c "select 1" 2>&1 | sed 's/^/  /'

echo "=== connection limits on Postgres ==="
psql -h "${PG_HOST}" -U admin -d postgres -Atc "select name||' = '||setting from pg_settings where name in ('max_connections','superuser_reserved_connections','reserved_connections') order by 1" | sed 's/^/  /'

echo "=== pg_dump through the pooler (transaction mode) ==="
for P in 6432 5432; do
  /usr/bin/time -f "  port $P: exit=%x  %e s" pg_dump -h "${PG_HOST}" -p $P -U admin -d postgres -t pgbench_branches -f /tmp/dump_$P.sql 2>&1 | sed 's/^/  /'
  echo "  port $P: dump has $(grep -c '^COPY\|^CREATE TABLE' /tmp/dump_$P.sql 2>/dev/null) COPY/CREATE lines"
done
pg_dump -h "${PG_HOST}" -p 6432 -U admin -d postgres -t pgbench_accounts -f /tmp/dump_acc.sql 2>&1 | head -3 | sed 's/^/  big table via 6432: /'; echo "  big table via 6432 exit=$? lines=$(wc -l </tmp/dump_acc.sql)"

echo "=== migration script through the pooler (psql -f, autocommit) under load ==="
cat > /tmp/migrate.sql <<'SQL'
SET lock_timeout = '2s';
SHOW lock_timeout;
ALTER TABLE pgbench_branches ADD COLUMN IF NOT EXISTS note text;
CREATE INDEX CONCURRENTLY IF NOT EXISTS pgbench_history_mtime_idx ON pgbench_history (mtime);
SHOW lock_timeout;
SQL
pgbench -h "${PG_HOST}" -p 6432 -U admin -n -S -c 40 -j 4 -T 30 postgres >/dev/null 2>&1 & BG=$!
sleep 2
for i in 1 2 3; do psql -h "${PG_HOST}" -p 6432 -U admin -d postgres -At -f /tmp/migrate.sql 2>&1 | paste -sd' ' | sed "s/^/  run $i: /"; psql -h "${PG_HOST}" -p 5432 -U admin -d postgres -qc "ALTER TABLE pgbench_branches DROP COLUMN IF EXISTS note; DROP INDEX IF EXISTS pgbench_history_mtime_idx"; done
wait $BG
echo ERRORS_DONE
