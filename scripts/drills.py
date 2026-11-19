#!/usr/bin/env python3
"""Transaction-mode drills: break each feature on purpose through PgBouncer and print what happened.

usage: drills.py <target>   target = managed | selfrun | selfrun-pool1 | direct
Password comes from ~/.pgpass. Run while background load uses the same pooler
(the caller starts `pgbench -S -c 40` so server connections get shared).

WARNING: run this only against a disposable database and a pool nobody else uses.
The drills change session state on shared server connections on purpose, run
DEALLOCATE ALL on a pooled connection, and terminate the backend left holding
the drill's advisory lock.
"""
import os, sys, time, threading, select
import psycopg
from psycopg import errors
PG = os.environ["PG_HOST"]            # Postgres host (direct, port 5432; managed pooler on 6432)
PGB = os.environ.get("PGB_HOST", "")  # self-run PgBouncer host

TARGETS = {
    "direct":        f"host={PG} port=5432 dbname=postgres user=admin sslmode=disable",
    "managed":       f"host={PG} port=6432 dbname=postgres user=admin sslmode=disable",
    "selfrun":       f"host={PGB} port=6432 dbname=postgres user=admin sslmode=disable",
    "selfrun-pool1": f"host={PGB} port=6432 dbname=leakdemo user=admin sslmode=disable",
}
DIRECT = TARGETS["direct"]
target = sys.argv[1]
DSN = TARGETS[target]


def conn(dsn=DSN, **kw):
    return psycopg.connect(dsn, autocommit=True, **kw)


def head(t):
    print(f"\n=== {t}  [{target}] ===", flush=True)


def err(e):
    return f"{type(e).__name__}: {str(e).strip().splitlines()[0]}"


# 1. SET leaking between clients -------------------------------------------------
def drill_set():
    head("1. SET leaking between clients")
    a = conn()
    a.execute("SET search_path TO leak_marker, public")
    print("client A ran: SET search_path TO leak_marker, public   (autocommit)")
    seen = 0
    for _ in range(20):
        with conn() as b:
            sp = b.execute("SHOW search_path").fetchone()[0]
            if "leak_marker" in sp:
                seen += 1
    print(f"20 new clients ran SHOW search_path: {seen}/20 saw 'leak_marker, public'")
    # same client, next statement
    own = a.execute("SHOW search_path").fetchone()[0]
    print(f"client A's own next statement sees: {own}")
    a.execute("RESET search_path")
    a.execute("SET statement_timeout = '1234ms'")
    print("client A ran: SET statement_timeout = '1234ms'   (autocommit)")
    seen = 0
    for _ in range(20):
        with conn() as b:
            if b.execute("SHOW statement_timeout").fetchone()[0] == "1234ms":
                seen += 1
    print(f"20 new clients ran SHOW statement_timeout: {seen}/20 saw 1234ms")
    own = a.execute("SHOW statement_timeout").fetchone()[0]
    print(f"client A's own next statement sees statement_timeout = {own}")
    a.execute("RESET statement_timeout")
    for _ in range(30):
        with conn() as c:
            c.execute("RESET statement_timeout")
    a.close()
    # fix: SET LOCAL inside a transaction
    a = psycopg.connect(DSN)
    with a.transaction():
        a.execute("SET LOCAL search_path TO leak_marker, public")
        inside = a.execute("SHOW search_path").fetchone()[0]
    a.close()
    seen = 0
    for _ in range(20):
        with conn() as b:
            if "leak_marker" in b.execute("SHOW search_path").fetchone()[0]:
                seen += 1
    print(f"fix — SET LOCAL inside BEGIN/COMMIT: inside the transaction = {inside}; afterwards {seen}/20 new clients saw it")


# 2. Prepared statements -----------------------------------------------------------
def drill_prepared():
    head("2a. protocol-level prepared statements (psycopg 3, prepare_threshold=0)")
    errs, ok = [], 0
    lock = threading.Lock()

    def worker():
        nonlocal ok
        try:
            c = psycopg.connect(DSN, autocommit=True, prepare_threshold=0)
            for i in range(50):
                c.execute("SELECT abalance FROM pgbench_accounts WHERE aid = %s", (i + 1,)).fetchone()
                with lock:
                    ok += 1
            c.close()
        except Exception as e:  # noqa
            with lock:
                errs.append(err(e))

    ts = [threading.Thread(target=worker) for _ in range(20)]
    [t.start() for t in ts]; [t.join() for t in ts]
    print(f"20 clients x 50 prepared executions: {ok} succeeded, {len(errs)} clients failed")
    for e in sorted(set(errs))[:3]:
        print("  error:", e)

    head("2b. SQL-level PREPARE / EXECUTE")
    c = conn()
    c.execute("PREPARE get_bal(int) AS SELECT abalance FROM pgbench_accounts WHERE aid = $1")
    fails, errs2 = 0, set()
    for i in range(30):
        try:
            c.execute("EXECUTE get_bal(1)").fetchone()
        except Exception as e:  # noqa
            fails += 1; errs2.add(err(e))
        time.sleep(0.05)
    print(f"PREPARE once, then EXECUTE 30 times from the same client: {fails}/30 failed")
    for e in sorted(errs2)[:2]:
        print("  error:", e)
    try:
        c.execute("DEALLOCATE ALL")
    except Exception:
        pass
    c.close()


# 3. LISTEN ---------------------------------------------------------------------------
def drill_listen():
    head("3. LISTEN / NOTIFY")
    l = conn()
    l.execute("LISTEN blog_channel")
    got = []
    l.add_notify_handler(lambda n: got.append(n.payload))
    time.sleep(1)
    with conn(DIRECT) as n:
        for i in range(5):
            n.execute(f"NOTIFY blog_channel, 'msg {i}'")
    for _ in range(40):          # keep using the listener so pending notifications get read
        l.execute("SELECT 1"); time.sleep(0.2)
    print(f"listener through {target}: received {len(got)}/5 notifications (NOTIFY sent on a direct connection)")
    with conn() as n:
        try:
            n.execute("NOTIFY blog_channel, 'via pooler'")
            print("NOTIFY sent through the pooler: accepted (no error)")
        except Exception as e:  # noqa
            print("NOTIFY through the pooler failed:", err(e))
    l.close()


# 4. Session-level advisory locks -----------------------------------------------------
def drill_advisory():
    head("4. session-level advisory locks")
    K = {"managed": 42, "selfrun": 52, "selfrun-pool1": 62, "direct": 72}[target]
    a, b = conn(), conn()
    ra = a.execute(f"SELECT pg_advisory_lock({K}), pg_backend_pid()").fetchone()
    print(f"client A: pg_advisory_lock({K}) -> ok, ran on backend pid {ra[1]}")
    rb = b.execute(f"SELECT pg_try_advisory_lock({K}), pg_backend_pid()").fetchone()
    print(f"client B: pg_try_advisory_lock({K}) -> {rb[0]} (backend pid {rb[1]})")
    holders = a.execute(f"SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND objid={K}").fetchone()[0]
    print(f"pg_locks rows for advisory lock {K}: {holders}")
    unl = []
    def notice(diag):
        unl.append(diag.message_primary)
    a.add_notice_handler(notice)
    r = a.execute(f"SELECT pg_advisory_unlock({K}), pg_backend_pid()").fetchone()
    print(f"client A: pg_advisory_unlock({K}) -> {r[0]} on backend pid {r[1]}" + (f"  NOTICE/WARNING: {unl[0]}" if unl else ""))
    a.close(); b.close()
    time.sleep(1)
    with conn(DIRECT) as d:
        left = d.execute(f"SELECT a.pid, a.application_name, a.client_addr::text FROM pg_locks l JOIN pg_stat_activity a USING (pid) WHERE l.locktype='advisory' AND l.objid={K}").fetchall()
        print(f"after both clients disconnected, lock {K} is still held by: {left}")
        d.execute(f"SELECT pg_terminate_backend(pid) FROM pg_locks WHERE locktype='advisory' AND objid={K} AND pid = {ra[1]}")  # only the backend client A locked on
    # fix
    c = psycopg.connect(DSN)
    with c.transaction():
        c.execute("SELECT pg_advisory_xact_lock(43)")
        inside = c.execute("SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND objid=43").fetchone()[0]
    after = conn(DIRECT).execute("SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND objid=43").fetchone()[0]
    print(f"fix — pg_advisory_xact_lock(43) inside a transaction: held inside = {inside}, after COMMIT = {after}")
    c.close()


# 5. Temp tables ---------------------------------------------------------------------
def drill_temp():
    head("5. temporary tables")
    a = conn()
    try:
        a.execute("DROP TABLE IF EXISTS pg_temp.tmp_report")
    except Exception:
        pass
    a.execute("CREATE TEMP TABLE tmp_report (x int)")   # ON COMMIT PRESERVE ROWS (default)
    fails, errs = 0, set()
    for i in range(30):
        try:
            a.execute("INSERT INTO tmp_report VALUES (%s)", (i,))
        except Exception as e:  # noqa
            fails += 1; errs.add(err(e))
        time.sleep(0.05)
    print(f"CREATE TEMP TABLE (PRESERVE ROWS), then 30 INSERTs from the same client: {fails}/30 failed")
    for e in sorted(errs)[:2]:
        print("  error:", e)
    others = 0
    for _ in range(20):
        with conn() as b:
            if b.execute("SELECT to_regclass('pg_temp.tmp_report') IS NOT NULL").fetchone()[0]:
                others += 1
    print(f"20 other new clients: {others}/20 can see client A's temp table")
    for _ in range(30):
        with conn() as c:
            c.execute("DROP TABLE IF EXISTS pg_temp.tmp_report")
    a.close()
    c = psycopg.connect(DSN)
    with c.transaction():
        c.execute("CREATE TEMP TABLE tmp_ok (x int) ON COMMIT DROP")
        c.execute("INSERT INTO tmp_ok SELECT generate_series(1,100)")
        n = c.execute("SELECT count(*) FROM tmp_ok").fetchone()[0]
    print(f"ON COMMIT DROP inside one transaction: created, filled, read {n} rows, dropped at COMMIT — works")
    c.close()


DRILLS = {"set": drill_set, "prepared": drill_prepared, "listen": drill_listen,
          "advisory": drill_advisory, "temp": drill_temp}

if __name__ == "__main__":
    which = sys.argv[2:] or list(DRILLS)
    for name in which:
        try:
            DRILLS[name]()
        except Exception as e:  # noqa
            print(f"drill {name} crashed: {err(e)}")
