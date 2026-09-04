#!/usr/bin/env bash
# Restaure la dernière sauvegarde chiffrée depuis Azure Blob dans une base
# PostgreSQL/TimescaleDB cible, puis vérifie que le résultat est
# exploitable. Sortie 0 = la sauvegarde est restaurable, sortie != 0 = non.
#
# Deux usages, même script :
#   - automatique, une fois par semaine, dans une base jetable
#     (.github/workflows/backup-restore-drill.yml) : c'est ce qui prouve
#     que les sauvegardes fonctionnent, plutôt que de prouver qu'un
#     fichier arrive dans Azure ;
#   - manuel, pendant un incident réel, contre la vraie base de secours
#     (procédure pas à pas dans docs/cicd/runbook.md).
#
# ⚠ Écrase le contenu de la base cible. Ne jamais viser une base de
#   production sans avoir lu la procédure d'incident.
#
# Variables :
#   RESTIC_REPOSITORY RESTIC_PASSWORD AZURE_ACCOUNT_NAME AZURE_ACCOUNT_KEY
#   BACKUP_TAG      tag restic à restaurer          (def. g4-db)
#   SNAPSHOT        id de snapshot ou "latest"      (def. latest)
#   PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE      (cible)
#   EXPECTED_TABLES_SQL  fichier de référence       (def. db/init/002_create_tables.sql)
#   MIN_TOTAL_ROWS  seuil d'échec sur le total      (def. 0 = ne juge que la structure)

set -euo pipefail

BACKUP_TAG="${BACKUP_TAG:-g4-db}"
SNAPSHOT="${SNAPSHOT:-latest}"
PGHOST="${PGHOST:-127.0.0.1}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-g4_app}"
PGDATABASE="${PGDATABASE:-g4_db}"
MIN_TOTAL_ROWS="${MIN_TOTAL_ROWS:-0}"

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
EXPECTED_TABLES_SQL="${EXPECTED_TABLES_SQL:-$repo_root/db/init/002_create_tables.sql}"

export PGHOST PGPORT PGUSER PGDATABASE

die() { echo "::error::$*" >&2; exit 1; }
step() { echo; echo "--- $* ---"; }

for v in RESTIC_REPOSITORY RESTIC_PASSWORD AZURE_ACCOUNT_NAME AZURE_ACCOUNT_KEY PGPASSWORD; do
  [ -n "${!v:-}" ] || die "variable $v absente"
done
export RESTIC_REPOSITORY RESTIC_PASSWORD AZURE_ACCOUNT_NAME AZURE_ACCOUNT_KEY PGPASSWORD

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

step "Snapshot ciblé (tag $BACKUP_TAG)"
restic snapshots --tag "$BACKUP_TAG" --latest 1

step "Récupération depuis Azure Blob"
restic restore "$SNAPSHOT" --tag "$BACKUP_TAG" --target "$workdir"

dump="$(find "$workdir" -type f -name '*.dump' | head -n1)"
[ -n "$dump" ] || die "aucun fichier .dump dans le snapshot restauré"
echo "dump récupéré : $dump ($(wc -c < "$dump") octets)"

step "Préparation de la base cible"
# TimescaleDB impose un encadrement précis autour de pg_restore : sans
# timescaledb_pre_restore(), les hypertables sont rechargées comme des
# tables ordinaires et la base obtenue est silencieusement cassée — les
# chunks existent mais le catalogue Timescale ne les connaît plus.
psql -v ON_ERROR_STOP=1 -c "CREATE EXTENSION IF NOT EXISTS timescaledb;"
psql -v ON_ERROR_STOP=1 -c "SELECT timescaledb_pre_restore();"

step "pg_restore"
restore_rc=0
pg_restore \
  --dbname="$PGDATABASE" \
  --no-owner \
  --no-privileges \
  --clean --if-exists \
  --exit-on-error \
  "$dump" || restore_rc=$?

# post_restore doit être appelé même si pg_restore a échoué, sinon la base
# reste bloquée en mode restauration.
psql -v ON_ERROR_STOP=1 -c "SELECT timescaledb_post_restore();"
[ "$restore_rc" -eq 0 ] || die "pg_restore a échoué (code $restore_rc)"

step "Vérification de structure"
[ -f "$EXPECTED_TABLES_SQL" ] || die "fichier de référence introuvable : $EXPECTED_TABLES_SQL"

expected="$(grep -oiE 'CREATE TABLE( IF NOT EXISTS)? +[a-z_]+' "$EXPECTED_TABLES_SQL" \
  | awk '{print $NF}' | sort -u)"
[ -n "$expected" ] || die "aucune table attendue extraite de $EXPECTED_TABLES_SQL"

actual="$(psql -tAc \
  "SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY 1;")"

missing=""
for t in $expected; do
  echo "$actual" | grep -qx "$t" || missing="$missing $t"
done
[ -z "$missing" ] || die "tables absentes après restauration :$missing"
echo "OK — toutes les tables attendues sont présentes :"
echo "$expected" | tr '\n' ' '; echo

step "Vérification de contenu"
total=0
for t in $expected; do
  n="$(psql -tAc "SELECT count(*) FROM public.\"$t\";")"
  printf '  %-24s %s lignes\n' "$t" "$n"
  total=$(( total + n ))
done
echo "total : $total lignes"

step "Hypertables TimescaleDB"
psql -c "SELECT hypertable_name, num_chunks FROM timescaledb_information.hypertables ORDER BY 1;"

if [ "$total" -lt "$MIN_TOTAL_ROWS" ]; then
  die "seulement $total lignes restaurées, seuil MIN_TOTAL_ROWS=$MIN_TOTAL_ROWS"
fi

echo
echo "DRILL RÉUSSI — la sauvegarde $BACKUP_TAG est restaurable ($total lignes)."
