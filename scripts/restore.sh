#!/usr/bin/env bash
# Restaure le dernier (ou un snapshot précis) instantané chiffré d'un
# service. Utilisé typiquement côté Azure pour alimenter "ml" avec les
# données produites on-premise, sans connexion réseau directe entre sites.
#
# Usage :
#   ./restore.sh db                 # dernier snapshot db
#   ./restore.sh db <snapshot-id>

set -euo pipefail

SERVICE="${1:?Usage: ./restore.sh <service> [snapshot-id]}"
SNAPSHOT="${2:-latest}"

: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY manquant}"
: "${RESTIC_PASSWORD:?RESTIC_PASSWORD manquant}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "→ récupération du snapshot $SNAPSHOT (tag g4-$SERVICE)"
restic restore "$SNAPSHOT" --tag "g4-$SERVICE" --target "$TMP_DIR"

DUMP_FILE="$(find "$TMP_DIR" -type f | head -n1)"
[ -n "$DUMP_FILE" ] || { echo "Aucun fichier trouvé dans le snapshot."; exit 1; }

if [ "$SERVICE" = "db" ]; then
  : "${POSTGRES_USER:?POSTGRES_USER manquant}"
  : "${POSTGRES_DB:?POSTGRES_DB manquant}"
  echo "→ restauration dans g4_db (écrase les données existantes)"
  docker exec -i g4_db pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    --clean --if-exists < "$DUMP_FILE"
else
  echo "→ archive récupérée dans $DUMP_FILE (restauration manuelle selon le service)"
fi

echo "OK — $SERVICE restauré depuis $SNAPSHOT"
