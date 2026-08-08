#! /bin/sh
# The engine backup. Mounted over /backup.sh in siemens/postgres-backup-s3:18,
# which supplies the S3 client, the scheduler and pg_dump 18.4 that the engine
# image lacks. The image's run.sh execs `go-cron "$SCHEDULE" /bin/sh backup.sh`
# from /, and that is the whole dependency on it.
#
# It writes ONE archive for each tenant database, plus ONE globals file for the
# engine. It never names a database to include — it reads pg_database — so a new
# tenant needs no change here and no compose change anywhere.
#
# It deliberately does NOT source the image's ./env.sh: that file exits 1 when
# POSTGRES_DATABASE is unset, and this script has no single database.
set -u

# --- Environment ----------------------------------------------------------
for v in POSTGRES_HOST POSTGRES_USER POSTGRES_PASSWORD S3_BUCKET S3_REGION PASSPHRASE; do
  eval "value=\${$v:-}"
  if [ -z "$value" ]; then
    echo "engine-backup: $v is not set. Refusing to run." >&2
    exit 1
  fi
done

export PGPASSWORD="$POSTGRES_PASSWORD"
export AWS_DEFAULT_REGION="$S3_REGION"
[ -n "${S3_ACCESS_KEY_ID:-}" ]     && export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID"
[ -n "${S3_SECRET_ACCESS_KEY:-}" ] && export AWS_SECRET_ACCESS_KEY="$S3_SECRET_ACCESS_KEY"

PORT="${POSTGRES_PORT:-5432}"
EXCLUDE="${BACKUP_EXCLUDE_DATABASES:-postgres}"
TIMESTAMP="$(date +"%Y-%m-%dT%H:%M:%S")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM

FAILED=0
DUMPED=0

# Encrypt, upload, and keep NO copy on the host disk. A local copy dies with the
# host, which is the failure the backup exists for.
ship() {
  _src="$1"; _key="$2"
  gpg --symmetric --batch --yes --passphrase "$PASSPHRASE" \
      --output "${_src}.gpg" "$_src" || return 1
  rm -f "$_src"
  aws s3 cp --only-show-errors "${_src}.gpg" "s3://${S3_BUCKET}/${_key}" || return 1
  rm -f "${_src}.gpg"
  return 0
}

# --- The set --------------------------------------------------------------
#
# datistemplate drops template1; datallowconn drops template0. Everything else
# is a tenant database unless the operator excluded it by name.
# The query goes in on STDIN, not through -c. psql does NOT interpolate a
# :'variable' inside -c, so the exclusion list would reach the server literally.
echo "engine-backup: reading pg_database from ${POSTGRES_HOST}:${PORT}"
if ! psql -tAX -v ON_ERROR_STOP=1 --no-psqlrc \
       -h "$POSTGRES_HOST" -p "$PORT" -U "$POSTGRES_USER" -d postgres \
       -v excl="$EXCLUDE" > "$WORK/databases" <<'SQL'
SELECT datname FROM pg_database
WHERE datistemplate = false
  AND datallowconn  = true
  AND datname <> ALL (
        ARRAY(SELECT btrim(x) FROM unnest(string_to_array(:'excl', ',')) AS x))
ORDER BY datname;
SQL
then
  echo "engine-backup: could not read pg_database. Nothing was backed up." >&2
  exit 1
fi

COUNT="$(grep -c . "$WORK/databases" || true)"

# An empty set looks exactly like a clean run, and it is the worst failure of
# the lot. It is also how a database that silently leaves the set breaks the run.
if [ "$COUNT" -eq 0 ]; then
  echo "engine-backup: pg_database returned NO databases to back up. Refusing to report success." >&2
  echo "engine-backup: exclusions in force: ${EXCLUDE}" >&2
  exit 1
fi

echo "engine-backup: ${COUNT} database(s) to back up. Exclusions: ${EXCLUDE}"

# --- One archive for each database ---------------------------------------
#
# Each database is a separate step. One failure must not stop the rest.
while IFS= read -r db; do
  [ -n "$db" ] || continue
  echo "engine-backup: dumping '${db}'"
  if ! pg_dump --format=custom \
        -h "$POSTGRES_HOST" -p "$PORT" -U "$POSTGRES_USER" -d "$db" \
        > "$WORK/db.dump"; then
    echo "engine-backup: FAILED to dump '${db}'" >&2
    FAILED=$((FAILED + 1))
    rm -f "$WORK/db.dump"
    continue
  fi
  if ! ship "$WORK/db.dump" "${db}/${TIMESTAMP}.dump.gpg"; then
    echo "engine-backup: FAILED to encrypt or upload '${db}'" >&2
    FAILED=$((FAILED + 1))
    rm -f "$WORK/db.dump" "$WORK/db.dump.gpg"
    continue
  fi
  DUMPED=$((DUMPED + 1))
  echo "engine-backup: uploaded ${db}/${TIMESTAMP}.dump.gpg"
done < "$WORK/databases"

# --- The globals, once for each run --------------------------------------
#
# A tenant role is a CLUSTER object, so pg_dump does not carry it. Restore an
# archive into an engine that holds no roles and it fails on the first
# `ALTER TABLE ... OWNER TO`. This file carries the SCRAM verifier of every
# tenant in one object, which is why the encryption above is mandatory and not
# merely prudent.
echo "engine-backup: dumping globals"
if ! pg_dumpall -h "$POSTGRES_HOST" -p "$PORT" -U "$POSTGRES_USER" --globals-only \
      > "$WORK/globals.sql"; then
  echo "engine-backup: FAILED to dump globals" >&2
  FAILED=$((FAILED + 1))
elif ! ship "$WORK/globals.sql" "globals/${TIMESTAMP}.sql.gpg"; then
  echo "engine-backup: FAILED to encrypt or upload globals" >&2
  FAILED=$((FAILED + 1))
else
  echo "engine-backup: uploaded globals/${TIMESTAMP}.sql.gpg"
fi

# --- The verdict ----------------------------------------------------------
#
# Retention is a 30-day S3 lifecycle rule on the bucket, not code here. The IAM
# user holds no s3:DeleteObject, so nothing below can erase a backup.
#
# NOBODY IS TOLD. Until the engine has monitoring, a failure is found by reading
# `docker logs engine-backup`.
if [ "$FAILED" -gt 0 ]; then
  echo "engine-backup: ${DUMPED} of ${COUNT} database(s) backed up, ${FAILED} step(s) FAILED." >&2
  exit 1
fi

echo "engine-backup: complete. ${DUMPED} database(s) and the globals, at ${TIMESTAMP}."
