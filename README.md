# Postgres host engine

One shared Postgres engine for every stack on a host, instead of one engine for each
application.

- **Postgres** with the **pgvector** extension.
- **pgbouncer** in front of it, for connection pooling.
- **PostgREST**, ready for a project that wants a REST API over its schema.
- **pgadmin**, behind the host proxy, for administration.

The stack runs on its own docker network and publishes no port on the host. A consumer in
another compose project joins that network by name and connects over it.

## Naming

`postgresd_host_engine` — the **`d`** marks a **docker**-only deployment. Postgres runs
as a container, driven by docker compose. Nothing is installed on the host itself.

`_host_` marks it as host-wide infrastructure, shared by every stack on the box, rather
than part of one application. It matches `traefikd_host_proxy`, which terminates TLS for
the same host.

## Status

Not built yet. The plan lives in the issues of this repo:

- **[Shared Postgres engine for a docker host](../../issues/1)** — the map. Read it first.
- Its child issues are the open decisions. Take one from the frontier: an open issue with
  nothing blocking it.

## Keep this repo generic

This repo is **public**. Every concrete value — the domain, the subdomains, the AWS
account, the bucket names, the host address, the certificate email, every credential —
belongs in `.env`, which is gitignored, or in private notes.

Never commit a real domain, subdomain, bucket name, host address, email, or account
identifier. Use `example.com` and a `${VARIABLE}` placeholder. The same rule applies to
the issues.

## Usage

Written once the stack exists. See **[Build the engine repo and start the
stack](../../issues/10)**.
