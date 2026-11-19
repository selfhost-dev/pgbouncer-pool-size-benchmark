-- Transaction-mode drills: the SQL each drill sends through PgBouncer (port 6432).
-- "Client A" / "client B" are separate connections. drills.py runs these with
-- psycopg 3 in autocommit while 40 pgbench -S clients share the same pool, and
-- once more through a one-connection pool (database "leakdemo") on the self-run pooler.
-- Results: drills_output.txt. Tested on PgBouncer 1.26.1, PostgreSQL 18.7.

-------------------------------------------------------------------------------
-- 1. Session settings
-------------------------------------------------------------------------------
-- client A
SET search_path TO leak_marker, public;
SHOW search_path;                              -- A's own next statement
-- 20 new clients, each:
SHOW search_path;                              -- count how many see leak_marker

-- client A
SET statement_timeout = '1234ms';
SHOW statement_timeout;                        -- A's own next statement
-- 20 new clients, each:
SHOW statement_timeout;                        -- count how many see 1234ms

-- fix: SET LOCAL inside one transaction
BEGIN;
SET LOCAL search_path TO leak_marker, public;
SHOW search_path;
COMMIT;
-- 20 new clients, each:
SHOW search_path;                              -- expect 0 see it

-------------------------------------------------------------------------------
-- 2. Prepared statements
-------------------------------------------------------------------------------
-- 2a protocol level: psycopg 3 with prepare_threshold=0, 20 clients x 50 runs of
--   SELECT abalance FROM pgbench_accounts WHERE aid = $1
-- and pgbench -M prepared -S -c 20 -T 10.
-- Run with max_prepared_statements = 0 and = 200 (self-run, via the admin console):
--   psql -d pgbouncer -c "SET max_prepared_statements = 0"
--   psql -d pgbouncer -c "RECONNECT postgres"

-- 2b SQL level, one client:
PREPARE get_bal(int) AS SELECT abalance FROM pgbench_accounts WHERE aid = $1;
EXECUTE get_bal(1);                            -- repeated 30 times, 50 ms apart
DEALLOCATE ALL;

-------------------------------------------------------------------------------
-- 3. LISTEN / NOTIFY
-------------------------------------------------------------------------------
-- listener, through the pooler
LISTEN blog_channel;
SELECT 1;                                      -- repeated for 8 s so pending notifications are read
-- sender, DIRECT to Postgres (port 5432)
NOTIFY blog_channel, 'msg 0';                  -- x5
-- sender, through the pooler
NOTIFY blog_channel, 'via pooler';

-------------------------------------------------------------------------------
-- 4. Session-level advisory locks
-------------------------------------------------------------------------------
-- client A
SELECT pg_advisory_lock(42), pg_backend_pid();
-- client B
SELECT pg_try_advisory_lock(42), pg_backend_pid();
-- client A
SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND objid = 42;
SELECT pg_advisory_unlock(42), pg_backend_pid();
-- after both disconnect, DIRECT:
SELECT a.pid, a.application_name, a.client_addr
FROM pg_locks l JOIN pg_stat_activity a USING (pid)
WHERE l.locktype = 'advisory' AND l.objid = 42;
-- clean-up, DIRECT:
SELECT pg_terminate_backend(pid) FROM pg_locks WHERE locktype = 'advisory' AND objid = 42;

-- fix
BEGIN;
SELECT pg_advisory_xact_lock(43);
SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND objid = 43;   -- 1
COMMIT;
-- DIRECT afterwards:
SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND objid = 43;   -- 0

-------------------------------------------------------------------------------
-- 5. Temporary tables
-------------------------------------------------------------------------------
-- client A
CREATE TEMP TABLE tmp_report (x int);          -- ON COMMIT PRESERVE ROWS (default)
INSERT INTO tmp_report VALUES (1);             -- repeated 30 times, 50 ms apart
-- 20 other new clients, each:
SELECT to_regclass('pg_temp.tmp_report') IS NOT NULL;

-- fix
BEGIN;
CREATE TEMP TABLE tmp_ok (x int) ON COMMIT DROP;
INSERT INTO tmp_ok SELECT generate_series(1, 100);
SELECT count(*) FROM tmp_ok;                   -- 100
COMMIT;

-------------------------------------------------------------------------------
-- 6. Migrations and dumps (errors.sh)
-------------------------------------------------------------------------------
-- migrate.sql, run with: psql -h <db> -p 6432 -At -f migrate.sql  (40 clients busy on the pool)
SET lock_timeout = '2s';
SHOW lock_timeout;
ALTER TABLE pgbench_branches ADD COLUMN IF NOT EXISTS note text;
CREATE INDEX CONCURRENTLY IF NOT EXISTS pgbench_history_mtime_idx ON pgbench_history (mtime);
SHOW lock_timeout;
-- undo, DIRECT:
ALTER TABLE pgbench_branches DROP COLUMN IF EXISTS note;
DROP INDEX IF EXISTS pgbench_history_mtime_idx;
-- dumps: pg_dump -p 6432 -t pgbench_branches; pg_dump -p 6432 -t pgbench_accounts
