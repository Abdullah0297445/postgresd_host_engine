#! /bin/sh
set -u

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

ship() {
  _src="$1"; _key="$2"
  gpg --symmetric --batch --yes --passphrase "$PASSPHRASE" \
      --output "${_src}.gpg" "$_src" || return 1
  rm -f "$_src"
  aws s3 cp --only-show-errors "${_src}.gpg" "s3://${S3_BUCKET}/${_key}" || return 1
  rm -f "${_src}.gpg"
  return 0
}

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

if [ "$COUNT" -eq 0 ]; then
  echo "engine-backup: pg_database returned NO databases to back up. Refusing to report success." >&2
  echo "engine-backup: exclusions in force: ${EXCLUDE}" >&2
  exit 1
fi

echo "engine-backup: ${COUNT} database(s) to back up. Exclusions: ${EXCLUDE}"

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

if [ "$FAILED" -gt 0 ]; then
  echo "engine-backup: ${DUMPED} of ${COUNT} database(s) backed up, ${FAILED} step(s) FAILED." >&2
  exit 1
fi

echo "engine-backup: complete. ${DUMPED} database(s) and the globals, at ${TIMESTAMP}."
