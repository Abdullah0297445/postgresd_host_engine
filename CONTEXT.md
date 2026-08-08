# Postgres host engine

One Postgres engine, shared by every stack on a host, instead of one engine for each
application. This file is the glossary. It holds no implementation detail.

## Language

**Engine**:
The stack this repo runs — Postgres, pgbouncer, pgadmin, and the backup script. It is
host-wide infrastructure, and it is not a tenant.
_Avoid_: server, cluster, database (for the whole thing)

**Tenant**:
One consumer compose project that holds a database on the engine. It owns at least one
database, and it never touches another tenant's data. A tenant that serves customers of its
own, inside its tenant database, is still **one** tenant. The engine never sees those
customers, and they are never tenants.
_Avoid_: consumer, client, project, app, user

**Tenant database**:
The database the engine holds for one tenant. The tenant's own role owns it.

**Tenant role**:
The one login role a tenant connects as. It owns its tenant database and reaches no other.
_Avoid_: user, account

**Engine superuser**:
The single superuser that provisions tenants and runs the backup. No tenant holds it.
_Avoid_: admin, root, postgres user

**Provisioning**:
Adding a tenant to a **running** engine — the role, the database, and the grants. The first
tenant and the fourth take the same path.
_Avoid_: seeding, bootstrapping, init

**DSN**:
The connection string the engine hands a tenant. It is the hand-off between this repo and a
consumer repo. It names a door.
_Avoid_: connection URL, database URL, credentials

**Door**:
The endpoint a tenant connects through to reach the engine. The engine holds two. They differ
only in how far a tenant may hold a connection, and the DSN names one of them. pgadmin is not
a door, because no tenant connects through it.
_Avoid_: pooler, endpoint, entrypoint

**Transaction door**:
The door for a tenant that keeps no state on the connection between transactions. It is the
default, and it lets many tenant connections share few engine connections.

**Session door**:
The door for a tenant that keeps state on the connection, such as a schema selection. It holds
one engine connection for as long as the tenant holds its own, so a tenant on this door must
release its connection promptly.

**Archive**:
The backup of one tenant database. The engine writes one for each tenant database it holds,
and one archive restores one tenant alone.
_Avoid_: dump, backup file, snapshot

**Globals**:
The engine-level objects that sit outside every tenant database — the tenant roles and their
passwords. They belong to the engine, not to a tenant, so one backup holds them for the whole
engine. That backup is as sensitive as the data, and it goes only into an engine that is
being rebuilt.
_Avoid_: users, roles file, cluster objects

**Drill**:
A rehearsal of a recovery, against a throwaway, to prove that the recovery works. A backup
that no drill has restored is not a backup.
_Avoid_: test, dry run

## Roles inside a tenant database, for PostgREST

These exist only in a tenant database that wants a REST API. PostgREST itself is **not** an
engine service; it runs in the tenant's own repo.

**Authenticator**:
The only role a PostgREST process logs in as. It holds no table rights, and it inherits
none, so it can do nothing until it takes another role.
_Avoid_: service account, api user

**Anon role**:
The role a PostgREST request takes when it carries no valid token. It cannot log in
directly.
_Avoid_: public role, guest

## Names used for the two pre-existing services

Both keep their own engines, and neither joins this one. They are named by their Postgres
major version, never by project name, because this repo is public.

**The PG 15 service** — the older of the two.

**The PG 17 service** — the newer of the two. It runs its own pgadmin.
