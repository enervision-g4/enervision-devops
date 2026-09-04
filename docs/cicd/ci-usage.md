# Brancher un dépôt de service sur la chaîne

`enervision-devops` ne contient aucun code applicatif : l'API, le
dashboard, le collecteur et les consommateurs vivent chacun dans leur
dépôt. Les tests unitaires et les linters de langage ne peuvent donc pas
s'exécuter ici.

La chaîne est publiée sous forme de **workflows réutilisables**
(`workflow_call`) que chaque dépôt de service appelle. Conséquence utile :
la politique de CI est définie une seule fois, et un changement — un
seuil, une version d'outil, une règle de sécurité — se propage à tous les
services sans les modifier un par un.

## Le fichier à créer dans chaque dépôt de service

`.github/workflows/ci-cd.yml` :

```yaml
name: CI/CD

on:
  push:
    branches: [develop, main]
  pull_request:
    branches: [develop, main]

permissions:
  contents: read
  packages: write

jobs:
  # 1. build + test : lint et tests unitaires
  ci:
    uses: enervision-g4/enervision-devops/.github/workflows/ci.yml@main
    with:
      language: python          # python | node
      run-tests: true           # false tant qu'il n'y a pas de test
      dockerfile: Dockerfile    # vide si le dépôt ne construit pas d'image

  # 2. scan : secrets, dépendances, image
  security-scan:
    uses: enervision-g4/enervision-devops/.github/workflows/security-scan.yml@main
    with:
      scan-terraform: false     # ces dépôts n'ont ni Terraform ni Ansible
      scan-ansible: false

  # 3. build de l'image et publication sur GHCR
  build-and-push:
    needs: [ci, security-scan]
    if: github.event_name == 'push'
    runs-on: ubuntu-latest
    outputs:
      image: ${{ steps.meta.outputs.image }}
    steps:
      - uses: actions/checkout@v7

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Set image tag
        id: meta
        run: echo "image=ghcr.io/enervision-g4/enervision-api:${{ github.sha }}" >> "$GITHUB_OUTPUT"

      - name: Build and push
        uses: docker/build-push-action@v7
        with:
          context: .
          push: true
          tags: ${{ steps.meta.outputs.image }}

  # 4. deploy : develop -> g4-dev, main -> g4-prod
  deploy:
    needs: build-and-push
    uses: enervision-g4/enervision-devops/.github/workflows/deploy.yml@main
    with:
      service: api            # correspond à infra/k8s/base/<service>/
      environment: onprem
      image: ${{ needs.build-and-push.outputs.image }}
    secrets: inherit
```

L'ordre `ci → security-scan → build-and-push → deploy` est ce qui rend
la séquence `build → test → scan → deploy` réellement contraignante :
un scan rouge empêche la publication de l'image, donc le déploiement.

## Réglage par dépôt

| Dépôt | `language` | `run-tests` | `service` | Remarque |
|---|---|---|---|---|
| `enervision-api` | `python` | `false` pour l'instant | `api` | `app/` et un `Dockerfile` existent, aucun test encore. Passer à `true` dès la première suite. |
| `enervision-etl` | `python` | `true` | `etl` | Déjà équipé : `pytest`, `ruff`, `mypy` configurés dans `pyproject.toml`. Pas de `Dockerfile` à ce jour. |
| `enervision-dashboard` | `node` | `true` | `dashboard` | Dépôt encore vide. |
| `enervision-messager-consumer` | `python` | `true` | `messager-consumer` | |

## Ce que le stage devient

`deploy.yml` déduit le stage de la branche appelante :

| Branche du dépôt de service | Stage | Namespace | Environment GitHub |
|---|---|---|---|
| `develop` | `dev` | `g4-dev` | `onprem-dev` |
| `main`, étiquette `v*` | `prod` | `g4-prod` | `onprem-prod` |

Pour forcer une cible, ajouter `stage: dev` (ou `prod`) dans le bloc
`with:` de l'appel à `deploy.yml`.

Un nouveau service a besoin de son manifeste dans
`infra/k8s/base/<service>/` avant que `deploy.yml` puisse le déployer —
voir la section « Ajouter un nouveau service » du README.

## Dependabot dans un dépôt de service

Ces blocs n'ont pas leur place dans `enervision-devops`, faute de
manifeste à y suivre. À ajouter dans `.github/dependabot.yml` du dépôt
concerné :

```yaml
version: 2
updates:
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "weekly"
    target-branch: "develop"

  # Dépôts Python (api, etl, ml, messager-consumer)
  - package-ecosystem: "pip"
    directory: "/"
    schedule:
      interval: "weekly"
    target-branch: "develop"
    groups:
      python-minor:
        update-types: ["minor", "patch"]

  # Dépôt Node (dashboard)
  - package-ecosystem: "npm"
    directory: "/"
    schedule:
      interval: "weekly"
    target-branch: "develop"
    groups:
      node-minor:
        update-types: ["minor", "patch"]

  - package-ecosystem: "docker"
    directory: "/"
    schedule:
      interval: "weekly"
    target-branch: "develop"
```

Le regroupement des versions mineures et correctives est ce qui évite
qu'un flot de PR quotidiennes finisse par faire ignorer les alertes qui
comptent.

## Ce qu'un dépôt de service doit fournir

1. Un `Dockerfile` produisant une image qui écoute sur le port attendu
   par son manifeste Kubernetes (`infra/k8s/base/<service>/`).
2. Pour l'API : la route `/health` renvoyant 200 — elle sert aux sondes
   de vivacité, au test de fumée post-déploiement et au contrôle de
   charge k6. Elle existe déjà dans `enervision-api`.
3. Une configuration lue **depuis l'environnement**, jamais depuis un
   fichier commité : le secret Kubernetes `g4-env` est injecté par
   `envFrom`.

## Voir aussi

- `quality-gates.md` — ce qui bloque et ce qui informe
- `architecture.md` — où ces composants s'exécutent
- `runbook.md` — Environments et secrets à créer
