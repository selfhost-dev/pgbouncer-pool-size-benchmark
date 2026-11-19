#!/usr/bin/env python3
"""Open N idle direct connections, hold them for S seconds, print start/end UTC times."""
import os, sys, time, psycopg
PG = os.environ["PG_HOST"]            # Postgres host (direct, port 5432; managed pooler on 6432)
PGB = os.environ.get("PGB_HOST", "")  # self-run PgBouncer host
n, s = int(sys.argv[1]), int(sys.argv[2])
dsn = f"host={PG} port=5432 dbname=postgres user=admin sslmode=disable"
print("open_start", time.strftime("%FT%TZ", time.gmtime()), flush=True)
cs = [psycopg.connect(dsn, autocommit=True) for _ in range(n)]
for c in cs:
    c.execute("SELECT 1")          # each backend has run one query, like a pool's idle connection
print("all_open", time.strftime("%FT%TZ", time.gmtime()), len(cs), flush=True)
time.sleep(s)
print("closing", time.strftime("%FT%TZ", time.gmtime()), flush=True)
for c in cs: c.close()
