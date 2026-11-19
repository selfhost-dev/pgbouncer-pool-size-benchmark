# PgBouncer pool size benchmark

The scripts, configuration and raw results behind the Selfhost.dev post
**"PgBouncer Pool Size, Measured: How Many Connections Postgres Actually Needs"**
(link: `<post-url>`).

Tested on 18 November 2026 with PostgreSQL 18.7 and PgBouncer 1.26.1 on AWS ap-south-1 (Mumbai).

## What was measured

- The same pgbench workloads, run directly against Postgres and through PgBouncer, at 50 to 1,000 clients
- Throughput and latency for `default_pool_size` values from 5 to 160, at 500 clients, on 2, 4 and 8 vCPU databases
- Six things transaction pooling breaks: session settings, prepared statements, `LISTEN`, advisory locks, temp tables and migrations
- PgBouncer's common errors, its own CPU use, and how fast new clients get in after a Postgres restart

## Setup

| Part | What we used |
|---|---|
| Database | Selfhost.dev managed PostgreSQL 18.7: m7i.large (2 vCPU, 8 GB), m7i.xlarge (4 vCPU), m7i.2xlarge (8 vCPU). 50 GB gp3, `max_connections` 512 |
| Managed pooler | Selfhost.dev managed pooling: PgBouncer 1.26.1 on the database host, port 6432 |
| Self-run pooler | PgBouncer 1.26.1 in Docker (`pgbouncer/`) on its own c7i.large in the same zone |
| Client | c7i.xlarge with 4 pgbench threads (c7i.2xlarge with 8 threads for the 8 vCPU sweep) |
| Data | `pgbench -i -s 100` (1,503 MB) |
| Workloads | A: TPC-B read/write. B: `pgbench -S`, read-only. C: `pgbench -C`, a new connection per transaction |

## Layout

```
pgbouncer/   pgbouncer.ini, docker-compose.yml and a userlist.txt example for the self-run pooler
scripts/     the pgbench runs, sweeps, drills, error cases and restart probe
data/        raw_numbers.csv (every run, one row each) and sweep_chart_data.csv (the pool-size sweep)
results/     raw output of each test
```

## Running it

Set these environment variables first:

| Variable | What it is |
|---|---|
| `PG_HOST` | Postgres host. Direct on 5432; a managed pooler on 6432 of the same host |
| `PGB_HOST` | Self-run PgBouncer host (port 6432) |
| `INSTANCE_PID` | Selfhost.dev instance id, only for the managed pool-size sweep |
| `PGB_THREADS` | pgbench threads (default 4) |
| `WORKDIR` | Where the scripts write `results/` and `tmp/` (default `~/pgb`) |

Passwords come from `~/.pgpass`; none are stored here. For the self-run pooler:

1. Copy `pgbouncer/userlist.txt.example` to `pgbouncer/userlist.txt`, put in the user's SCRAM
   verifier (`SELECT rolpassword FROM pg_authid WHERE rolname = 'admin'` on the server), and
   run `chmod 600 pgbouncer/userlist.txt`. Git ignores this file.
2. Replace `<postgres-host>` in `pgbouncer/pgbouncer.ini` with your Postgres address.
3. `listen_addr` is `127.0.0.1`. To reach the pooler from a separate client machine, set it
   to the host's private address and allow only that client in your firewall. Never expose
   port 6432 to the internet: the admin console (`admin_users`) is on the same port.
4. Run `docker compose up -d` in `pgbouncer/`.

**Use a disposable database and a pooler nobody else uses.** The scripts change pooler
settings (`SET default_pool_size`, `RECONNECT`, `SET query_wait_timeout`), add and drop a
column and an index on `pgbench_branches`, dump tables to `/tmp`, and the drills change
session state on shared connections on purpose.

**TLS was off.** Every run used `sslmode=disable` so TLS stayed out of the measured path,
and the scripts keep that setting. Use `sslmode=require` or stricter for anything that
crosses a network you don't control.

Run the scripts from `scripts/` on the client machine:

| Script | What it does |
|---|---|
| `run.sh <label> <host> <port> <A\|B\|C> <clients> [seconds]` | One pgbench run, plus Postgres backend counts and `SHOW POOLS` each second |
| `matrix.sh` | Direct vs managed pooler, workloads A, B and C at 50, 200, 500 and 1,000 clients |
| `sweep_selfrun.sh <tag>` | Pool sizes 5 to 160 on the self-run pooler (sets `default_pool_size` through the admin console, then `RECONNECT`) |
| `sweep_managed.sh`, `sweep_managed_only.sh` | The same sweep on Selfhost.dev managed pooling. They set the pool size through the `selfhost` CLI and ran from a laptop, sending each run to the client with a small SSH wrapper (`./vm client <command>`, not included). Run `run.sh` on the client yourself to reproduce them elsewhere |
| `burst.sh` | 50 steady clients plus a 450-client burst, to test `reserve_pool_size` |
| `drills.py managed\|selfrun\|selfrun-pool1` | The six transaction-mode drills; `drills.sql` lists their statements |
| `errors.sh`, `probe.py` | The error cases, and a connect-and-`SELECT 1` probe every 100 ms during a restart |
| `idle_mem.py` | Memory per idle direct connection |

## Reading the numbers

Each sweep point ran once for 60 seconds. We repeated five tests about ten minutes apart:
four landed within 2% of each other, and one read-only test differed by 49%
(49,255 vs 73,555 TPS). Treat small differences between single runs as noise.

Your workload, network and instance sizes will give different numbers. The point of the
sweep is the shape: throughput rises with the pool size, flattens, then falls.

## License

MIT. See [LICENSE](LICENSE).
