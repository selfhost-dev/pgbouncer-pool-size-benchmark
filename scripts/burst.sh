#!/bin/bash
set -u
: "${2:?usage: burst.sh <label> <host>}"
WORKDIR=${WORKDIR:-$HOME/pgb}
# Burst: 50 steady clients for 60 s; 450 more join at t=20 s for 20 s. Same pooler.
# usage: burst.sh <label> <host>   -> p50/p95/p99 of the steady clients and of the burst clients
cd "$WORKDIR"; L=$1; H=$2; mkdir -p tmp/$L; cd tmp/$L; rm -f pgbench_log.*
ulimit -n 65535
pgbench -h "$H" -p 6432 -U admin -n -c 50 -j 2 -T 60 -l --log-prefix=steady postgres > steady.out 2>&1 &
sleep 20
pgbench -h "$H" -p 6432 -U admin -n -c 450 -j 2 -T 20 -l --log-prefix=burst postgres > burst.out 2>&1
wait
pct(){ f=$1; n=$(wc -l < $f); for p in .50 .95 .99; do awk -v n=$n -v p=$p 'NR==int(n*p+0.5){printf "%.1f ", $1/1000; exit}' $f; done; }
# steady clients, only the 20 s window when the burst ran (epoch column 5)
T0=$(cat burst.* 2>/dev/null | awk 'NR==1{print $5}'); [ -z "$T0" ] && T0=$(awk 'NR==1{print $5+20}' steady.*)
cat steady.* | awk -v a=$T0 '$5>=a && $5<a+20 {print $3}' | sort -n > steady.lat
cat steady.* | awk -v a=$T0 '$5<a {print $3}' | sort -n > before.lat
cat burst.* | awk '{print $3}' | sort -n > burst.lat
echo "$L steady-before-burst p50/p95/p99 ms: $(pct before.lat) | steady-during-burst: $(pct steady.lat) | burst clients: $(pct burst.lat) | errors: $(grep -ch error steady.out burst.out | paste -sd+ | bc)"
