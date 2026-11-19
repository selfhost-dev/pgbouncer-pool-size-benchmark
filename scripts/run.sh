#!/bin/bash
set -u
: "${PG_HOST:?set PG_HOST first (see README)}"
WORKDIR=${WORKDIR:-$HOME/pgb}
# One pgbench run with side measurements.
# usage: run.sh <label> <host> <port> <workload A|B|C> <clients> [duration_s=60]
# Writes results/<label>.{out,lat,backends,pools} and prints one summary line (TSV).
LABEL=$1 HOST=$2 PORT=$3 WL=$4 CL=$5 DUR=${6:-60}
DB_HOST=${PG_HOST}
mkdir -p "$WORKDIR/results" "$WORKDIR/tmp"; cd "$WORKDIR/tmp"; rm -f pgbench_log.*
ulimit -n 65535
case $WL in A) OPTS="";; B) OPTS="-S";; C) OPTS="-C";; esac
J=${PGB_THREADS:-4}; [ "$CL" -lt $J ] && J=$CL
R="$WORKDIR"/results/$LABEL
# backends on Postgres (direct connection, 1 s sampling; the sampler itself is 1 backend)
( end=$((SECONDS+DUR+5)); while [ $SECONDS -lt $end ]; do
    psql -h "$DB_HOST" -p 5432 -U admin -d postgres -Atc "select count(*) filter (where backend_type='client backend'), count(*) filter (where backend_type='client backend' and state='active') from pg_stat_activity" 2>/dev/null; sleep 1; done > $R.backends ) &
SB=$!
# SHOW POOLS on the self-run pooler
if [ "$HOST" = "${PGB_HOST}" ]; then
  ( end=$((SECONDS+DUR+5)); while [ $SECONDS -lt $end ]; do
      psql -h "${PGB_HOST}" -p 6432 -U admin -d pgbouncer -Atc "SHOW POOLS" 2>/dev/null | grep '^postgres|admin|'; sleep 1; done > $R.pools ) &
  SP=$!
fi
( LC_ALL=C mpstat 5 $((DUR/5)) > $R.clientcpu 2>&1 ) &
START=$(date -u +%FT%TZ)
pgbench -h $HOST -p $PORT -U admin -n $OPTS -c $CL -j $J -T $DUR -P 10 -l --sampling-rate=0.2 postgres > $R.out 2>&1
RC=$?
END=$(date -u +%FT%TZ)
wait $SB; [ -n "${SP:-}" ] && wait $SP
cat pgbench_log.* 2>/dev/null | awk '{print $3}' | sort -n > $R.lat
N=$(wc -l < $R.lat)
pct(){ [ "$N" -gt 0 ] && awk -v n=$N -v p=$1 'NR==int(n*p+0.5){printf "%.1f", $1/1000; exit}' $R.lat || echo NA; }
TPS=$(grep -oP 'tps = \K[0-9.]+' $R.out | head -1)
FAILED=$(grep -oP 'number of failed transactions: \K[0-9]+' $R.out | head -1)
ERR=$(grep -m1 -iE 'error|fatal|abort' $R.out | tr '\t' ' ' | cut -c1-160)
BMAX=$(awk -F'|' 'BEGIN{m=0}{if($1>m)m=$1}END{print m}' $R.backends)
BACT=$(awk -F'|' 'BEGIN{m=0}{if($2>m)m=$2}END{print m}' $R.backends)
POOLS=NA
[ -f $R.pools ] && POOLS=$(awk -F'|' 'BEGIN{cw=0;mw=0;sa=0}{if($4>cw)cw=$4; if($14>mw)mw=$14; if($7>sa)sa=$7}END{print "cl_waiting_max="cw" maxwait_s_max="mw" sv_active_max="sa}' $R.pools)
printf '%s\t%s\t%s\t%s\t%s\ttps=%s\tp50=%s\tp95=%s\tp99=%s\tfailed=%s\tbackends_max=%s\tactive_max=%s\t%s\trc=%s\t%s\t%s\terr=%s\n' \
  "$LABEL" "$HOST:$PORT" "$WL" "$CL" "$DUR" "${TPS:-NA}" "$(pct .50)" "$(pct .95)" "$(pct .99)" "${FAILED:-0}" "$BMAX" "$BACT" "$POOLS" "$RC" "$START" "$END" "${ERR:-}" | tee -a "$WORKDIR/results/summary.tsv"
