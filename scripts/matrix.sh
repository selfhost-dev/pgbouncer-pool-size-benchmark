#!/bin/bash
set -u
: "${PG_HOST:?set PG_HOST first (see README)}"
WORKDIR=${WORKDIR:-$HOME/pgb}
# Direct vs managed pooler: workloads A/B/C at 50/200/500/1000 clients, 60 s each.
cd "$WORKDIR"
for WL in A B C; do for CL in 50 200 500 1000; do
  ./run.sh m-direct-$WL-$CL "${PG_HOST}" 5432 $WL $CL 60; sleep 10
  ./run.sh m-managed-$WL-$CL "${PG_HOST}" 6432 $WL $CL 60; sleep 10
done; done
echo MATRIX_DONE
