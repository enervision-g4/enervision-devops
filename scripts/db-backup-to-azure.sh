#!/usr/bin/env sh
# Sauvegarde chiffrée de TimescaleDB vers Azure Blob Storage, via restic.
#
# Un seul fichier pour les deux chemins d'exécution, pour qu'il n'y ait
# qu'une logique de sauvegarde à maintenir et à auditer :
#
#   dump   pg_dump seul          -> initContainer du CronJob k8s
#   push   restic seul           -> conteneur principal du CronJob k8s
#   all    les deux à la suite   -> exécution manuelle / cron hôte
#          (rôle Ansible db-backup-agent), quand pg_dump ET restic sont
#          présents sur la même machine
#
# Aucune image ne fournit à la fois pg_dump et restic, d'où la découpe.
#
# Variables (toutes fournies par le secret g4-env / le .env de l'hôte) :
#   POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB
#   PGHOST                hôte de la base            (def. g4-db)
#   PGPORT                port                       (def. 5432)
#   DUMP_PATH             fichier intermédiaire      (def. /work/g4_db.dump)
#   RESTIC_REPOSITORY     ex. azure:g4-backups:/restic-prod
#   RESTIC_PASSWORD       passphrase du dépôt
#   AZURE_ACCOUNT_NAME AZURE_ACCOUNT_KEY
#   BACKUP_TAG            tag restic                 (def. g4-db)
#   KEEP_DAILY KEEP_MONTHLY  rétention                (def. 30 / 12)
#
# Rétention : elle est appliquée par `restic forget --prune`, JAMAIS par
# une règle de cycle de vie Azure sur l'âge des blobs. Un dépôt restic est
# déduplique : supprimer un blob par son âge détruit des morceaux encore
# référencés par des snapshots récents et corrompt tout le dépôt. Voir
# docs/cicd/runbook.md.

set -eu

MODE="${1:-all}"

PGHOST="${PGHOST:-g4-db}"
PGPORT="${PGPORT:-5432}"
DUMP_PATH="${DUMP_PATH:-/work/g4_db.dump}"
BACKUP_TAG="${BACKUP_TAG:-g4-db}"
KEEP_DAILY="${KEEP_DAILY:-30}"
KEEP_MONTHLY="${KEEP_MONTHLY:-12}"

die() { echo "ERREUR: $*" >&2; exit 1; }

need() {
  for v in "$@"; do
    eval "val=\${$v:-}"
    [ -n "$val" ] || die "variable $v absente"
  done
}

do_dump() {
  need POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB
  PGPASSWORD="$POSTGRES_PASSWORD"
  export PGPASSWORD

  echo "pg_dump ${PGHOST}:${PGPORT}/${POSTGRES_DB} -> ${DUMP_PATH}"
  # -Fc : format custom, compressé et restaurable sélectivement.
  # --no-owner / --no-privileges : le dump doit pouvoir être rechargé dans
  # une base de secours où les rôles du serveur d'origine n'existent pas
  # (c'est exactement le cas du drill de restauration).
  pg_dump \
    --host="$PGHOST" \
    --port="$PGPORT" \
    --username="$POSTGRES_USER" \
    --dbname="$POSTGRES_DB" \
    --format=custom \
    --no-owner \
    --no-privileges \
    --file="$DUMP_PATH"

  [ -s "$DUMP_PATH" ] || die "le dump est vide"
  echo "dump OK : $(wc -c < "$DUMP_PATH") octets"
}

do_push() {
  need RESTIC_REPOSITORY RESTIC_PASSWORD AZURE_ACCOUNT_NAME AZURE_ACCOUNT_KEY
  [ -s "$DUMP_PATH" ] || die "aucun dump à envoyer ($DUMP_PATH)"
  export RESTIC_REPOSITORY RESTIC_PASSWORD AZURE_ACCOUNT_NAME AZURE_ACCOUNT_KEY

  if ! restic cat config >/dev/null 2>&1; then
    echo "initialisation du dépôt $RESTIC_REPOSITORY"
    restic init
  fi

  echo "envoi chiffré (tag $BACKUP_TAG)"
  restic backup "$DUMP_PATH" --tag "$BACKUP_TAG"

  echo "rétention : $KEEP_DAILY quotidiennes, $KEEP_MONTHLY mensuelles"
  restic forget --tag "$BACKUP_TAG" \
    --keep-daily "$KEEP_DAILY" \
    --keep-monthly "$KEEP_MONTHLY" \
    --prune

  # Vérifie l'intégrité des métadonnées et d'un échantillon de données :
  # une sauvegarde qu'on n'a jamais relue n'est pas une sauvegarde.
  restic check --read-data-subset=5%

  echo "snapshots présents :"
  restic snapshots --tag "$BACKUP_TAG"
}

case "$MODE" in
  dump) do_dump ;;
  push) do_push ;;
  all)  do_dump; do_push ;;
  *)    die "mode inconnu '$MODE' (attendu: dump | push | all)" ;;
esac

echo "sauvegarde terminée ($MODE)"
