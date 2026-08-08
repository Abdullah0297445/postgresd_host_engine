# Postgres host engine

One shared Postgres engine for every stack on a host, instead of one engine for each
application.

- **Postgres 18** with the **pgvector** extension.
- **pgbouncer** in front of it, as **two doors** — one transaction, one session.
- **pgadmin**, behind the host proxy, for administration.
- A **backup** that discovers every tenant database by itself and writes one archive for
  each, plus one globals file for the engine.

**PostgREST is not a service in this stack.** One PostgREST process serves exactly one
database, so it belongs to the tenant it serves, in that tenant's repo. What this repo
ships is a **template**: the compose service block in `templates/postgrest.compose.yml`,
and the role recipe, executable as `WITH_API=1` on the provisioning command.

The stack runs on its own docker network and publishes no port on the host. A consumer in
another compose project joins that network by name and connects over it.

## Naming

`postgresd_host_engine` — the **`d`** marks a **docker**-only deployment. Postgres runs
as a container, driven by docker compose. Nothing is installed on the host itself.

`_host_` marks it as host-wide infrastructure, shared by every stack on the box, rather
than part of one application. It matches `traefikd_host_proxy`, which terminates TLS for
the same host.

## Usage

1. `cp .env.example .env`
2. Make appropriate changes to the values in the `.env` file. Every password must change.
3. Confirm `.gitignore` excludes `.env` **before** the first commit. This repo is public.
4. Create the docker network by running this command in your terminal:
   `docker network create postgres_host_network`
5. `traefikd_host_proxy` must already be running, so that `traefik_host_network` exists
   and `${PGADMIN_HOST}` has a DNS A record pointing at this host.
6. `docker compose up -d`
7. `docker compose ps` — every container must reach a healthy state, and none may show a
   host port binding.

## Adding a tenant

A **tenant** is one consumer compose project. It gets one database, one login role that
owns that database, and one DSN. The first tenant and the fourth take the same path.

```
make add-tenant NAME=<name>
```

The name is used **verbatim** as both the database name and the role name. No prefix, no
suffix, and no letter is removed. Names outside `[a-z0-9_]` are rejected, because the name
goes straight into SQL identifiers — the command refuses bad input rather than quietly
rewriting good input.

| Flag | What it adds |
|---|---|
| `SESSION=1` | The printed DSN names the **session door** instead of the transaction door. |
| `WITH_API=1` | The `api` schema, the authenticator and anonymous roles, and the `pgrst_watch` event trigger. Prints a second DSN for PostgREST. |

The command prints the DSN once. **The engine keeps no copy you can read back** — paste it
into the consumer repo's own gitignored `.env`, and keep the master record in your private
notes.

It is safe to run again: an existing tenant makes it stop, not overwrite.

### Which door

The **DSN** selects the door. The engine holds no per-tenant line, and adding a tenant
never touches pgbouncer.

| Door | Alias | For |
|---|---|---|
| Transaction | `engine` | The default. A tenant that keeps no state on the connection between transactions. |
| Session | `engine-session` | A tenant that keeps state on the connection, such as a schema selection with `SET search_path`. |

**A tenant on the session door must keep `CONN_MAX_AGE = 0`.** That door holds one engine
connection for as long as the tenant holds its own. Raise it and each thread pins a server
connection, the pool exhausts, and requests block. This is why 200 Django threads can run
against a pool of 25: `CONN_MAX_AGE = 0` makes a session one request long.

Both doors listen on port **5432**, so no tenant ever writes a port. If a tenant fails on
the transaction door, move its DSN to `engine-session` — that is a DSN change, not an
engine change.

### Removing a tenant

Manual, on purpose. It drops data and it is rare, so it gets no command.

```
docker compose exec postgres psql -U postgres -c 'DROP DATABASE <name>;'
docker compose exec postgres psql -U postgres -c 'DROP ROLE <name>;'
```

The tenant's archives stop being written at the next run, and its S3 folder expires by
itself under the lifecycle rule.

## Backups

`@daily`, by a script this repo owns, running inside `siemens/postgres-backup-s3:18` —
that image supplies the S3 client, the scheduler and `pg_dump` 18.4 that the engine image
lacks. The script is mounted over the image's own `/backup.sh`, so **no image is built
here**.

It reads `pg_database`, so **no tenant is ever named**. It writes:

```
<database>/<timestamp>.dump.gpg     one for each tenant database
globals/<timestamp>.sql.gpg         one for the engine
```

Everything is encrypted with `gpg --symmetric` under `${BACKUP_PASSPHRASE}`. **Lose that
passphrase and every archive is waste.**

The globals file exists because a tenant role is a **cluster** object: it is not inside
the tenant database, so `pg_dump` does not carry it. Restore an archive into an engine
that holds no roles and it fails on the first `ALTER TABLE ... OWNER TO`. That file
carries the SCRAM verifier of every tenant in one object, so it is as sensitive as the
data itself.

**Retention is 30 days, as an S3 lifecycle rule on the bucket** — not code in this repo.
The IAM user deliberately holds **no** `s3:DeleteObject`, so an engine that is compromised
cannot erase its own backups, and a fault in the script cannot either. A reader of this
repo cannot see that rule, which is why it is written here.

Run it once, out of schedule, with `make backup-now`.

`scripts/backup.sh` is a **single-file bind mount**, which pins the inode. Editing it does
**not** reach the running container — recreate it afterwards:

```
docker compose up -d --force-recreate backup
```

**Nobody is told when it fails.** The run exits non-zero if any database failed **or if
the set came back empty** — an empty set looks exactly like a clean run and is the worst
failure of the lot. Until the engine has monitoring, you find a failure by reading
`docker logs engine-backup`. The same is true of `log_temp_files` and
`log_autovacuum_min_duration`, which are both on and both write only to `docker logs`.

## Restoring

Three paths. **The globals file belongs to one of them.**

**1. One tenant, into a throwaway — this is the drill.** No globals, and it names no
tenant role, so it carries no password into the target.

```
aws s3 cp s3://${S3_BUCKET}/<database>/<timestamp>.dump.gpg .
gpg --decrypt --batch --passphrase "${BACKUP_PASSPHRASE}" <timestamp>.dump.gpg > db.dump
docker compose exec postgres createdb -U postgres drill
docker compose exec -T postgres pg_restore -U postgres --no-owner --no-acl -d drill < db.dump
```

**2. One tenant, back into the running engine.** No globals — the role is already there.

```
docker compose exec postgres createdb -U postgres <database>
docker compose exec -T postgres pg_restore -U postgres -d <database> < db.dump
```

**3. The whole engine is lost.** This is the only path that loads the globals file, and
the only event where every tenant role is wanted, because every tenant comes back at once.
Load the globals **first**, then restore each archive.

`maintenance_work_mem` is 256MB globally and its context is `user`, so a restore raises it
in its own session — `SET maintenance_work_mem = '1GB';` — and gives it back at the end.
The engine does not carry a large value all day to serve an occasional restore.

## Design notes

### Memory

The engine takes **5 GB across all five containers**, and Postgres takes **4 GB** of that.
Every container has a `mem_limit` and a matching `memswap_limit`, so **nothing swaps** — a
database that swaps is slower than one that is down, and it stays "up" while it drags its
neighbours with it. There is no `cpus` limit anywhere; parallelism is capped inside
Postgres with `max_parallel_workers` instead.

`shared_buffers` is 1GB, which is 25% of the **container limit** — not of the box. The
priced worst case at 120 connections sits 487 MiB under the limit.

Only Postgres takes a `shm_size`, at `256m`. Postgres 18 still fails a parallel hash join
on docker's default 64 MB `/dev/shm`. It is a cap, not a reservation.

Settings travel as compose `command:` flags, never as a mounted `postgresql.conf`. The
image writes its own conf into the volume at first start, so a mounted file would have to
replace it whole and could then drift from the image.

### Authentication between a door and the engine

Neither door holds a copy of any tenant password, and neither has a `userlist.txt` of
tenants. Both use `auth_query` against a `SECURITY DEFINER` function installed **once** in
the `postgres` database — `auth_dbname` is pinned there, so the function does not have to
go into every tenant database. Reading the verifier straight out of the catalog is what
makes the SCRAM secrets identical on both sides, which SCRAM pass-through requires.

The one line each door does write into its own `userlist.txt` at start-up is for
`${PGBOUNCER_AUTH_USER}`, the lookup role, whose own password pgbouncer must know before
it can ask anything. That role has no table rights and reaches only the `postgres`
database.

### Rotating the pgbouncer lookup role

`initdb/01-engine-auth.sh` runs **only on an empty volume**. To change
`PGBOUNCER_AUTH_PASSWORD` on an engine that already has data, edit `.env` and then apply
the same script by hand:

```
docker compose exec -T postgres sh /docker-entrypoint-initdb.d/01-engine-auth.sh
docker compose up -d --force-recreate pgbouncer-transaction pgbouncer-session
```

It is written to be safe to re-run.

### What bypasses the doors

pgadmin, the backup script, and any PostgREST all reach Postgres **directly**. pgadmin
keeps idle session-level connections and runs `SET`; `pg_dump` through a transaction
pooler fails; and PostgREST has its own pool, while transaction pooling breaks its
`LISTEN` schema reload silently. The network layout enforces this: the backup script joins
the compose `default` network only, so it cannot take a pooled path by accident.

### Blast radius

When the engine stops, **every** tenant loses its database at once, and any restart to
change `shared_buffers` takes them all down together. This is accepted: the box is already
the failure domain — one host, one docker daemon — so a shared engine adds no new single
point of failure. Two conditions hold it there: keep this compose file small, so restarts
stay rare, and hold nothing in the engine except tenant databases.

## Notes

- This repo is **public**. Every concrete value — the domain, the subdomains, the AWS
  account, the bucket name, the host address — lives in `.env`, which is gitignored. Never
  write a real domain, bucket name, host address, email, or account identifier into this
  repo.
- pgadmin registers exactly **one** server, this engine, from a checked-in
  `pgadmin/servers.json` with `PGADMIN_REPLACE_SERVERS_ON_STARTUP=True`. The repo wins at
  every start, so a server you add by hand does not survive a restart. It logs in as the
  engine superuser and **never saves the password**; you type it each session.
- pgadmin is the only part of the engine the internet can reach, and it stands behind two
  locks: a traefik `basicauth` middleware on the `-secure` router, and its own login. Its
  image floats on `latest` on purpose, so security fixes arrive without review. Its volume
  needs no backup — it holds one server definition and no password.
- `${RESOLVER_NAME}` must match the value in the `traefikd_host_proxy` `.env`.
