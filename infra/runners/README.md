# Runners self-hosted GitHub Actions

## Setup initial
1. Copier .env.example vers .env et renseigner GH_PAT_ORG
2. docker compose -f docker-compose.runners.yml up -d
3. Vérifier sur GitHub : Settings > Actions > Runners

## Redémarrage après crash VM

Si la machine virtuelle a redémarré ou planté, suivez ces étapes pour remonter l'infrastructure :

Vérifier le statut de Docker
Assurez-vous que le service Docker tourne correctement.

```bash
sudo systemctl status docker
```

(Si le service est inactif, démarrez-le avec ```bash sudo systemctl start docker```)

Relancer les conteneurs
Une fois Docker opérationnel, relancez les runners.

```bash
docker compose -f docker-compose.runners.yml up -d
```
