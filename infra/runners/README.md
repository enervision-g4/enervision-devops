# Runners self-hosted GitHub Actions

## Setup initial
1. Copier .env.example vers .env et renseigner GH_PAT_ORG
2. docker compose -f docker-compose.runners.yml up -d
3. Vérifier sur GitHub : Settings > Actions > Runners

## Redémarrage après crash VM
sudo systemctl status docker  # vérifier que Docker tourne
docker compose -f docker-compose.runners.yml up -d
