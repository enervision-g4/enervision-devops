#!/usr/bin/env sh
# Encrypted TimescaleDB backup to a restic repository (Azure Blob in
# production).
#
# One file for both execution paths, so that there is only one backup
# logic to maintain and audit:
#
#   dump   pg_dump only          -> initContainer of the k8s CronJob
#   push   restic only           -> main container of the k8s CronJob
#   all    both in sequence      -> manual run / host cron
#          (db_backup_agent Ansible role), when pg_dump AND restic are
#          available on the same machine
#
# No single image ships both pg_dump and restic, hence the split.
#
# Variables (all supplied by the g4-env secret / the host .env):
#   POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB
#   G4_DB_CONTAINER       container to dump through docker exec (Compose)
#   PGHOST                database host, when no container (def. g4-db)
#   PGPORT                port                         (def. 5432)
#   DUMP_PATH             intermediate file            (def. /work/g4_db.dump)
#   RESTIC_REPOSITORY     e.g. azure:g4-backups:/restic-prod
#   RESTIC_PASSWORD       repository passphrase
#   AZURE_ACCOUNT_NAME AZURE_ACCOUNT_KEY
#   BACKUP_TAG            restic tag                   (def. g4-db)
#   KEEP_DAILY KEEP_MONTHLY  retention                 (def. 30 / 12)
#
# Retention is applied by `restic forget --prune`, NEVER by a storage
# lifecycle rule deleting blobs by age. A restic repository is
# deduplicated: deleting a blob because it is old destroys chunks still
# referenced by recent snapshots and corrupts the whole repository.
# See docs/cicd/backup-restore.md.

set -eu

MODE="${1:-all}"

PGHOST="${PGHOST:-g4-db}"
PGPORT="${PGPORT:-5432}"
DUMP_PATH="${DUMP_PATH:-/work/g4_db.dump}"
BACKUP_TAG="${BACKUP_TAG:-g4-db}"
KEEP_DAILY="${KEEP_DAILY:-30}"
KEEP_MONTHLY="${KEEP_MONTHLY:-12}"

die() { echo "ERROR: $*" >&2; exit 1; }

need() {
  for v in "$@"; do
    eval "val=\${$v:-}"
    [ -n "$val" ] || die "variable $v is not set"
  done
}

do_dump() {
  need POSTGRES_USER POSTGRES_DB

  # Two ways to reach the database, depending on how it runs:
  #
  #   G4_DB_CONTAINER set -> `docker exec` into the container. This is the
  #     current Compose deployment, where the PostgreSQL port is not
  #     published on the host: there is nothing to reach over the network.
  #   otherwise           -> plain TCP connection, for a database
  #     reachable over the network.
  #
  # Everything else — encryption, retention, repository — is identical in
  # both cases: that is the whole point of having a single script.
  if [ -n "${G4_DB_CONTAINER:-}" ]; then
    echo "pg_dump through docker exec ${G4_DB_CONTAINER} -> ${DUMP_PATH}"
    docker exec -e PGPASSWORD="${POSTGRES_PASSWORD:-}" "$G4_DB_CONTAINER" \
      pg_dump \
        --username="$POSTGRES_USER" \
        --dbname="$POSTGRES_DB" \
        --format=custom \
        --no-owner \
        --no-privileges > "$DUMP_PATH"

    [ -s "$DUMP_PATH" ] || die "the dump is empty"
    echo "dump OK: $(wc -c < "$DUMP_PATH") bytes"
    return
  fi

  need POSTGRES_PASSWORD
  PGPASSWORD="$POSTGRES_PASSWORD"
  export PGPASSWORD

  echo "pg_dump ${PGHOST}:${PGPORT}/${POSTGRES_DB} -> ${DUMP_PATH}"
  # --format=custom: compressed, and restorable table by table.
  # --no-owner / --no-privileges: the dump must reload into a recovery
  # database where the original server's roles do not exist — which is
  # exactly the situation during an incident.
  pg_dump \
    --host="$PGHOST" \
    --port="$PGPORT" \
    --username="$POSTGRES_USER" \
    --dbname="$POSTGRES_DB" \
    --format=custom \
    --no-owner \
    --no-privileges \
    --file="$DUMP_PATH"

  [ -s "$DUMP_PATH" ] || die "the dump is empty"
  echo "dump OK: $(wc -c < "$DUMP_PATH") bytes"
}

do_push() {
  need RESTIC_REPOSITORY RESTIC_PASSWORD
  [ -s "$DUMP_PATH" ] || die "no dump to upload ($DUMP_PATH)"
  export RESTIC_REPOSITORY RESTIC_PASSWORD

  # Which credentials are needed depends on the repository type, not on
  # this script: restic reads AZURE_* for azure:, AWS_* for s3:, nothing
  # for sftp: or a local path. Requiring only what the target actually
  # needs is what makes "switching provider = changing RESTIC_REPOSITORY"
  # true rather than aspirational (see docs/cicd/infra-decision.md).
  case "$RESTIC_REPOSITORY" in
    azure:*)
      need AZURE_ACCOUNT_NAME AZURE_ACCOUNT_KEY
      export AZURE_ACCOUNT_NAME AZURE_ACCOUNT_KEY
      ;;
    s3:*)
      need AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
      export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
      ;;
  esac

  # A distro-packaged restic is sometimes built WITHOUT the cloud
  # backends: the azure: or s3: scheme is then rejected before any
  # connection, with an "invalid backend" that says nothing actionable.
  # This reuses the call already made to test whether the repository
  # exists, so the check costs nothing extra.
  probe="$(restic cat config 2>&1)" && repo_exists=1 || repo_exists=0
  case "$probe" in
    *"invalid backend"*)
      die "this restic binary does not support the '${RESTIC_REPOSITORY%%:*}:' scheme.
       Install restic from github.com/restic/restic/releases, or use the
       restic/restic image. Some distribution packages are built without
       the cloud backends. See docs/cicd/backup-restore.md."
      ;;
  esac

  if [ "$repo_exists" -eq 0 ]; then
    echo "initialising repository $RESTIC_REPOSITORY"
    restic init
  fi

  echo "encrypted upload (tag $BACKUP_TAG)"
  restic backup "$DUMP_PATH" --tag "$BACKUP_TAG"

  echo "retention: $KEEP_DAILY daily, $KEEP_MONTHLY monthly"
  restic forget --tag "$BACKUP_TAG" \
    --keep-daily "$KEEP_DAILY" \
    --keep-monthly "$KEEP_MONTHLY" \
    --prune

  # Checks the metadata and a sample of the data: a backup that has never
  # been read back is not a backup.
  restic check --read-data-subset=5%

  echo "snapshots present:"
  restic snapshots --tag "$BACKUP_TAG"
}

case "$MODE" in
  dump) do_dump ;;
  push) do_push ;;
  all)  do_dump; do_push ;;
  *)    die "unknown mode '$MODE' (expected: dump | push | all)" ;;
esac

echo "backup finished ($MODE)"
