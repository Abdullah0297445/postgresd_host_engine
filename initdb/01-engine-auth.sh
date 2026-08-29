#!/bin/bash
set -euo pipefail

if [ -z "${PGBOUNCER_AUTH_USER:-}" ] || [ -z "${PGBOUNCER_AUTH_PASSWORD:-}" ]; then
  echo "engine: PGBOUNCER_AUTH_USER and PGBOUNCER_AUTH_PASSWORD must both be set." >&2
  exit 1
fi

psql -v ON_ERROR_STOP=1 --no-psqlrc \
     --username "$POSTGRES_USER" --dbname postgres \
     -v authuser="$PGBOUNCER_AUTH_USER" -v authpw="$PGBOUNCER_AUTH_PASSWORD" <<'SQL'

-- The lookup role. No table rights, and it reaches the postgres database only,
-- so REVOKE CONNECT ... FROM PUBLIC on each tenant database is untouched.
SELECT format('CREATE ROLE %I LOGIN', :'authuser')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'authuser')
\gexec

ALTER ROLE :"authuser"
  WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION
  PASSWORD :'authpw';

-- SECURITY DEFINER, so the lookup role needs no rights on pg_authid itself.
-- Reading the verifier straight out of the catalog is what makes the SCRAM
-- secrets identical in pgbouncer and in Postgres — same salt, same iterations —
-- which SCRAM pass-through requires.
CREATE OR REPLACE FUNCTION public.pgbouncer_get_auth(p_usename TEXT)
RETURNS TABLE(usename TEXT, passwd TEXT)
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
  SELECT usename::TEXT, passwd::TEXT
  FROM pg_catalog.pg_shadow
  WHERE usename = p_usename;
$$;

REVOKE EXECUTE ON FUNCTION public.pgbouncer_get_auth(TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.pgbouncer_get_auth(TEXT) TO :"authuser";

SQL

echo "engine: pgbouncer lookup role and auth_query function installed."
