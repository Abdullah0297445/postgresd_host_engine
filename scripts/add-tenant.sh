#!/bin/sh
set -eu

NAME="${NAME:-}"
WITH_API="${WITH_API:-}"
SESSION="${SESSION:-}"

die() { echo "add-tenant: $1" >&2; exit 1; }

[ -n "$NAME" ] || die "NAME is required. Try: make add-tenant NAME=myapp"

case "$NAME" in
  *[!a-z0-9_]*) die "'$NAME' is not a valid name. Use lower case a-z, 0-9 and _ only." ;;
esac

[ "$(printf %s "$NAME" | wc -c)" -le 63 ] || die "'$NAME' is longer than 63 characters."

AUTHENTICATOR="${NAME}_authenticator"
ANON="${NAME}_anon"
if [ -n "$WITH_API" ] && [ "$(printf %s "$AUTHENTICATOR" | wc -c)" -gt 63 ]; then
  die "'$NAME' is too long for WITH_API: the role '$AUTHENTICATOR' would exceed 63 characters."
fi

engine() {
  docker compose exec -T -e ENGINE_DB="$1" postgres sh -c \
    'exec psql -v ON_ERROR_STOP=1 --no-psqlrc --quiet --username "$POSTGRES_USER" --dbname "$ENGINE_DB"'
}

engine_q() {
  docker compose exec -T -e ENGINE_DB="$1" -e ENGINE_SQL="$2" postgres sh -c \
    'exec psql -tAX -v ON_ERROR_STOP=1 --no-psqlrc --username "$POSTGRES_USER" --dbname "$ENGINE_DB" -c "$ENGINE_SQL"'
}

engine_q postgres "SELECT 1" >/dev/null 2>&1 \
  || die "cannot reach the engine. Start it with: docker compose up -d"

if [ "$(engine_q postgres "SELECT 1 FROM pg_database WHERE datname = '$NAME'")" = "1" ]; then
  die "the database '$NAME' already exists. Nothing was changed."
fi
if [ "$(engine_q postgres "SELECT 1 FROM pg_roles WHERE rolname = '$NAME'")" = "1" ]; then
  die "the role '$NAME' exists without its database. Nothing was changed."
fi

newpw() { od -An -tx1 -N16 /dev/urandom | tr -d ' \n'; }
PASSWORD="$(newpw)"
[ "$(printf %s "$PASSWORD" | wc -c)" -eq 32 ] || die "could not read 16 bytes from /dev/urandom."

engine postgres <<SQL
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', '$NAME', '$PASSWORD') \gexec
SELECT format('CREATE DATABASE %I OWNER %I', '$NAME', '$NAME') \gexec
SQL

engine postgres <<SQL
BEGIN;
SELECT format('REVOKE CONNECT ON DATABASE %I FROM PUBLIC', '$NAME') \gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', '$NAME', '$NAME') \gexec
COMMIT;
SQL

engine "$NAME" <<'SQL'
BEGIN;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
-- `vector` is NOT a trusted extension, so a database owner cannot create it
-- later without coming back to the engine owner. Doing it now costs nothing.
CREATE EXTENSION IF NOT EXISTS vector;
COMMIT;
SQL

API_PASSWORD=""
if [ -n "$WITH_API" ]; then
  API_PASSWORD="$(newpw)"
  engine "$NAME" <<SQL
BEGIN;
SELECT format('CREATE SCHEMA IF NOT EXISTS api AUTHORIZATION %I', '$NAME') \gexec

-- The authenticator holds NO table rights and inherits none. NOINHERIT is the
-- detail that silently breaks least privilege when it is forgotten: without it
-- the authenticator carries the anon role's rights on every connection, before
-- PostgREST has run its SET LOCAL ROLE.
SELECT format('CREATE ROLE %I LOGIN NOINHERIT NOCREATEDB NOCREATEROLE NOSUPERUSER PASSWORD %L',
              '$AUTHENTICATOR', '$API_PASSWORD') \gexec
SELECT format('CREATE ROLE %I NOLOGIN', '$ANON') \gexec
SELECT format('GRANT %I TO %I', '$ANON', '$AUTHENTICATOR') \gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', '$NAME', '$AUTHENTICATOR') \gexec
SELECT format('GRANT USAGE ON SCHEMA api TO %I', '$ANON') \gexec

-- The schema-cache reload. An event trigger is a superuser-only object, so only
-- the engine can install it — which is why it belongs to provisioning and not
-- to the tenant. A stale cache is the commonest PostgREST complaint, and this
-- makes a migration update the API by itself.
CREATE OR REPLACE FUNCTION public.pgrst_watch() RETURNS event_trigger
  LANGUAGE plpgsql AS \$\$
BEGIN
  NOTIFY pgrst, 'reload schema';
END;
\$\$;

SELECT 'CREATE EVENT TRIGGER pgrst_watch ON ddl_command_end EXECUTE FUNCTION public.pgrst_watch()'
WHERE NOT EXISTS (SELECT 1 FROM pg_event_trigger WHERE evtname = 'pgrst_watch')
\gexec
COMMIT;
SQL
fi

if [ -n "$SESSION" ]; then
  DOOR="engine-session"
  DOOR_NAME="SESSION door"
else
  DOOR="engine"
  DOOR_NAME="TRANSACTION door"
fi

echo
echo "Tenant '$NAME' is provisioned."
echo
echo "  Join the engine network in the consumer's compose file:"
echo
echo "    networks:"
echo "      postgres_host_network:"
echo "        external: true"
echo
echo "  FOR THE APPLICATION. Through the ${DOOR_NAME}, which is pgbouncer."
echo "  Paste this into the consumer repo's own gitignored .env:"
echo
echo "    DATABASE_URL=postgresql://${NAME}:${PASSWORD}@${DOOR}:5432/${NAME}"
echo

if [ -n "$SESSION" ]; then
  cat <<'WARN'
  This DSN names the SESSION door. That door holds one engine connection for as
  long as the tenant holds its own, so the tenant MUST keep CONN_MAX_AGE = 0
  (Django's default). Raise it and each thread pins a server connection, the
  pool exhausts, and requests block.

WARN
fi

if [ -n "$WITH_API" ]; then
  cat <<API
  FOR POSTGREST. DIRECT to the engine, and NOT through a door.
  Paste this into the consumer repo's own gitignored .env:

    PGRST_DB_URI=postgres://${AUTHENTICATOR}:${API_PASSWORD}@postgres:5432/${NAME}

  Roles installed: schema 'api', authenticator '${AUTHENTICATOR}', anonymous
  role '${ANON}'. Copy the service block from templates/postgrest.compose.yml
  into the consumer's repo.

  THE TWO STRINGS ABOVE ARE NOT INTERCHANGEABLE.
  DATABASE_URL names '${DOOR}', which is a pooler. PGRST_DB_URI names
  'postgres', and it must never name a door: transaction pooling breaks
  PostgREST's LISTEN schema reload silently, and every health check still
  passes, so a wrong paste looks exactly like a right one. Before you paste
  PGRST_DB_URI, check that it holds '_authenticator' and '@postgres'.

API
fi

cat <<'NOTE'
  This is the only time these passwords are shown. The engine keeps no copy you
  can read back. Record them in your private notes now.

NOTE
