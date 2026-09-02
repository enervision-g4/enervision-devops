#!/usr/bin/env bash
# Sauvegarde chiffrée et portable d'un service, via restic (compatible
# Azure Blob, S3/OVH/AWS, SFTP, disque local — cible définie par
# RESTIC_REPOSITORY dans le .env de l'environnement).
#
# Usage :
#   ./backup.sh db         # pg_dump du conteneur g4_db
#   ./backup.sh <service> --volume <volume_name>   # backup générique d'un volume Docker
#
# Le type de service détermine juste comment on produit l'archive à
# chiffrer/envoyer ; le reste (chiffrement, rétention, backend) est
# strictement identique pour tous les services.

set -euo pipefail

SERVICE="${1:?Usage: ./backup.sh <service> [--volume <name>]}"
shift || true

: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY manquant}"
: "${RESTIC_PASSWORD:?RESTIC_PASSWORD manquant}"

command -v restic >/dev/null || { echo "restic n'est pas installé."; exit 1; }

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

if [ "$SERVICE" = "db" ]; then
  : "${POSTGRES_USER:?POSTGRES_USER manquant}"
  : "${POSTGRES_DB:?POSTGRES_DB manquant}"
  echo "→ pg_dump depuis g4_db"
  docker exec g4_db pg_dump -U "$POSTGRES_USER" -Fc "$POSTGRES_DB" > "$TMP"
else
  VOLUME="${2:?--volume <name> requis pour un service non-db}"
  echo "→ archive du volume $VOLUME"
  docker run --rm -v "$VOLUME":/data -v "$(dirname "$TMP")":/backup \
    alpine tar czf "/backup/$(basename "$TMP")" -C /data .
fi

restic snapshots >/dev/null 2>&1 || restic init

echo "→ envoi chiffré vers $RESTIC_REPOSITORY"
restic backup "$TMP" --tag "g4-$SERVICE" --tag "$(date +%Y-%m-%d)"

restic forget --tag "g4-$SERVICE" \
  --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune

echo "OK"
