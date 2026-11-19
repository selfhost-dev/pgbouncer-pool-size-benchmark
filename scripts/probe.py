#!/usr/bin/env python3
"""Run `SELECT 1` every 100 ms on a fresh connection and log every failure.

usage: probe.py <label> <dsn> <seconds>
Prints the first and last failure, the distinct errors, and the outage length.
"""
import sys, time
import psycopg

label, dsn, secs = sys.argv[1], sys.argv[2], float(sys.argv[3])
end = time.time() + secs
fails, errors, first, last = 0, {}, None, None
ok = 0
while time.time() < end:
    t = time.time()
    try:
        with psycopg.connect(dsn, autocommit=True, connect_timeout=3) as c:
            c.execute("SELECT 1")
        ok += 1
    except Exception as e:  # noqa
        fails += 1
        msg = str(e).strip().splitlines()[0][:160]
        errors[msg] = errors.get(msg, 0) + 1
        first = first or t
        last = t
    time.sleep(max(0, 0.1 - (time.time() - t)))
fmt = lambda x: time.strftime("%H:%M:%S", time.gmtime(x)) + f".{int(x % 1 * 10)}" if x else "-"
print(f"[{label}] ok={ok} failed={fails} first_fail={fmt(first)} last_fail={fmt(last)} "
      f"outage_s={(last - first + 0.1) if first else 0:.1f}")
for m, n in sorted(errors.items(), key=lambda kv: -kv[1]):
    print(f"[{label}]   {n}x {m}")
