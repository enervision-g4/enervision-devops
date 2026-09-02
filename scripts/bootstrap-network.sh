#!/usr/bin/env bash
# À lancer une fois par environnement (on-premise, Azure, OVH...), avant le
# premier déploiement de n'importe quel service.

set -euo pipefail

docker network inspect g4_net >/dev/null 2>&1 && {
  echo "g4_net existe déjà."
  exit 0
}

docker network create g4_net
echo "Réseau g4_net créé."
