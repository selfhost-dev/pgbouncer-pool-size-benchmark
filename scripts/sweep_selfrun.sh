#!/bin/bash
set -u
: "${PGB_HOST:?set PGB_HOST first (see README)}"
WORKDIR=${WORKDIR:-$HOME/pgb}
SCRIPTS=$(cd "$(dirname "$0")" && pwd)
# Pool-size sweep on the self-run PgBouncer: 500 clients, workload A, 60 s per size.
# usage: sweep_selfrun.sh <tag>   (tag = instance size, e.g. 2vcpu)
cd "$WORKDIR"; TAG=$1
for P in 5 10 20 40 80 160; do
  psql -h "${PGB_HOST}" -p 6432 -U admin -d pgbouncer -qc "SET default_pool_size = $P" -c "SET reserve_pool_size = 0"
  # drop the old server connections so every size starts from the same state
  psql -h "${PGB_HOST}" -p 6432 -U admin -d pgbouncer -qc "RECONNECT postgres" >/dev/null 2>&1
  sleep 5
  "$SCRIPTS/run.sh" s-selfrun-$TAG-pool$P "${PGB_HOST}" 6432 A 500 60
  sleep 10
done
psql -h "${PGB_HOST}" -p 6432 -U admin -d pgbouncer -qc "SET default_pool_size = 20" -c "SET reserve_pool_size = 5"
echo SWEEP_SELFRUN_DONE
