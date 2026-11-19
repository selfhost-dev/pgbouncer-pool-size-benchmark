#!/bin/bash
# Managed pool-size sweep: set default_pool_size through the API, then 500 clients x 60 s.
TAG=$1; PID=${INSTANCE_PID}
for P in 5 10 20 40 80 160; do
  echo "{\"default_pool_size\":$P,\"reserve_pool_size\":0,\"min_pool_size\":0}" | selfhost api -X PUT /aws/v1/instances/$PID/pgbouncer --input - -o json | jq -c '{p:.data.pgbouncer.default_pool_size, r:.data.pgbouncer.reserve_pool_size, msg:.message}'
  for i in $(seq 1 30); do st=$(selfhost api -X GET /aws/v1/instances/$PID/pgbouncer -o json | jq -r .data.pgbouncer.status); [ "$st" = enabled ] && break; sleep 5; done
  sleep 5
  ./vm client "cd ~/pgb && ./run.sh s-managed-$TAG-pool$P ${PG_HOST} 6432 A 500 60" | cut -f1,6-9,11-12,14
  sleep 10
done
echo '{"default_pool_size":20,"reserve_pool_size":5,"min_pool_size":0}' | selfhost api -X PUT /aws/v1/instances/$PID/pgbouncer --input - -o json | jq -c '{restored:.data.pgbouncer.default_pool_size}'
./vm client "cd ~/pgb && ./sweep_selfrun.sh $TAG" | cut -f1,6-9,11-14
echo SWEEPS_DONE
