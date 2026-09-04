#!/usr/bin/env bash
# Applique un stage EnerVision sur le cluster k3s.
#
# Point d'entrée unique, utilisé à l'identique par la CI
# (.github/workflows/deploy-k8s.yml) et à la main sur le serveur : la
# séquence de déploiement n'existe qu'à un seul endroit.
#
#   ./scripts/k8s-apply.sh <dev|prod> [service] [image]
#
#   ./scripts/k8s-apply.sh dev
#       applique l'ensemble du stage dev (base de données, Kafka,
#       supervision, sauvegarde) sans toucher aux images applicatives.
#
#   ./scripts/k8s-apply.sh prod api ghcr.io/enervision-g4/enervision-api:abc123
#       même chose, mais en épinglant d'abord l'image de l'api à ce tag,
#       puis en attendant la fin du rollout de ce seul service.
#
# Trois ressources ne sont volontairement PAS dans les manifestes :
#   g4-env             secret, construit depuis ENV_FILE_CONTENTS
#   g4-db-initdb       ConfigMap, construite depuis db/init/*.sql
#   g4-backup-script   ConfigMap, construite depuis scripts/db-backup-to-azure.sh
# Les deux ConfigMaps évitent de dupliquer le SQL et le script dans les
# manifestes : le chemin Compose et le chemin k3s lisent les mêmes
# fichiers. Le secret, lui, n'a simplement rien à faire dans un dépôt Git.

set -euo pipefail

STAGE="${1:-}"
SERVICE="${2:-}"
IMAGE="${3:-}"

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
overlay="$repo_root/infra/k8s/overlays/$STAGE"

die() { echo "ERREUR: $*" >&2; exit 1; }
step() { echo; echo "--- $* ---"; }

case "$STAGE" in
  dev|prod) ;;
  *) die "usage: $0 <dev|prod> [service] [image]" ;;
esac
[ -d "$overlay" ] || die "overlay introuvable : $overlay"
[ -n "${ENV_FILE_CONTENTS:-}" ] || die "ENV_FILE_CONTENTS est vide (secret de l'Environment onprem-$STAGE)"

command -v kubectl >/dev/null || die "kubectl absent"
if [ -n "$IMAGE" ]; then
  command -v kustomize >/dev/null || die "kustomize absent (requis pour épingler une image)"
fi

NS="g4-$STAGE"

step "Namespace $NS"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

step "Secret g4-env"
envfile="$(mktemp)"
trap 'rm -f "$envfile"' EXIT
printf '%s\n' "$ENV_FILE_CONTENTS" > "$envfile"
kubectl -n "$NS" create secret generic g4-env \
  --from-env-file="$envfile" \
  --dry-run=client -o yaml | kubectl apply -f -

step "ConfigMaps (SQL d'initialisation, script de sauvegarde)"
kubectl -n "$NS" create configmap g4-db-initdb \
  --from-file="$repo_root/db/init/" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$NS" create configmap g4-backup-script \
  --from-file="$repo_root/scripts/db-backup-to-azure.sh" \
  --dry-run=client -o yaml | kubectl apply -f -

if [ -n "$SERVICE" ] && [ -n "$IMAGE" ]; then
  step "Épinglage de l'image : $SERVICE -> $IMAGE"
  # `kustomize edit` modifie overlays/<stage>/kustomization.yaml. En CI
  # c'est un checkout jetable ; sur l'hôte, la modification reste locale
  # et documente quelle image tourne réellement.
  ( cd "$overlay" && kustomize edit set image "ghcr.io/enervision-g4/enervision-$SERVICE=$IMAGE" )
fi

step "kubectl apply -k overlays/$STAGE"
kubectl apply -k "$overlay"

step "Attente du rollout"
if [ -n "$SERVICE" ]; then
  kubectl -n "$NS" rollout status "deployment/g4-$SERVICE" --timeout=5m
else
  # Rollout complet : on attend la base et le bus d'abord (les autres en
  # dépendent), puis les composants applicatifs déployés.
  kubectl -n "$NS" rollout status statefulset/g4-db --timeout=10m
  kubectl -n "$NS" rollout status statefulset/g4-kafka --timeout=10m
  for d in $(kubectl -n "$NS" get deployments -o name); do
    replicas="$(kubectl -n "$NS" get "$d" -o jsonpath='{.spec.replicas}')"
    [ "$replicas" = "0" ] && { echo "$d : 0 replica, ignoré"; continue; }
    kubectl -n "$NS" rollout status "$d" --timeout=5m
  done
fi

step "État du namespace $NS"
kubectl -n "$NS" get pods,svc,ingress,cronjob

echo
echo "Déploiement terminé sur $NS."
