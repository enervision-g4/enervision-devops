# enervision-devops

Dépôt central de déploiement pour tous les services du projet
(`enervision-api`, `enervision-dashboard`, `enervision-etl`,
`enervision-messager-consumer`, et l'infrastructure partagée comme la
base de données). Aucun de ces dépôts ne sait déployer lui-même : chacun
construit son image, puis appelle un **workflow réutilisable** défini ici
pour effectuer le déploiement réel.

Rien dans cette organisation n'est spécifique à un service en particulier
— la base de données est traitée exactement comme les autres
(`infra/k8s/base/db/` a la même forme que `infra/k8s/base/api/`).

## Structure

```
.
├── .github/
│   ├── workflows/
│   │   ├── ci.yml                   # réutilisable : lint + tests unitaires
│   │   ├── security-scan.yml        # réutilisable : gitleaks, Trivy, checkov, ansible-lint
│   │   ├── deploy.yml               # réutilisable : appelé par les dépôts de service
│   │   ├── deploy-k8s.yml           # rollout dans un namespace du cluster
│   │   ├── deploy-dev.yml           # develop → g4-dev, puis k6 + ZAP
│   │   ├── deploy-prod.yml          # main/tag → g4-prod, bloqué si dev est rouge
│   │   ├── backup-restore-drill.yml # exercice de restauration hebdomadaire
│   │   └── enforce-branch-flow.yml  # règle de flux de branches
│   └── dependabot.yml
├── infra/
│   ├── k8s/                         # manifestes kustomize (base + overlays dev/prod)
│   ├── terraform/                   # Azure : stockage des sauvegardes
│   ├── ansible/                     # provisionnement des machines (k3s, durcissement)
│   └── runners/                     # runners GitHub self-hosted
├── docs/cicd/                       # architecture, décision d'infra, runbook, portes de qualité
├── scripts/
│   ├── k8s-apply.sh                 # point d'entrée unique du déploiement
│   ├── db-backup-to-azure.sh        # sauvegarde chiffrée (CronJob k8s et hôte)
│   └── db-restore-drill.sh          # restauration + contrôle d'intégrité
├── envs/k3s.env.example             # forme du secret ENV_FILE_CONTENTS
└── db/init/                         # scripts SQL d'initialisation
```

## CI/CD & Infrastructure

Les composants tournent dans un cluster **k3s** sur le serveur
on-premise, séparés en deux namespaces `g4-dev` et `g4-prod`. **Azure
n'est utilisé que pour stocker les sauvegardes chiffrées de la base** —
aucune charge applicative n'y tourne.

La chaîne suit l'ordre `build → test → scan → deploy`. `ci.yml` et
`security-scan.yml` sont publiés ici comme workflows *réutilisables* que
chaque dépôt de service appelle — les tests applicatifs vivent dans ces
dépôts, pas ici.

| Document | Contenu |
|---|---|
| [`docs/cicd/architecture.md`](docs/cicd/architecture.md) | schémas de déploiement et de la chaîne CI/CD, prolongeant EC01 |
| [`docs/cicd/k8s-primer.md`](docs/cicd/k8s-primer.md) | **à lire en premier si Kubernetes n'est pas familier** — les huit notions utilisées ici, et les questions probables en soutenance |
| [`docs/cicd/infra-decision.md`](docs/cicd/infra-decision.md) | pourquoi on-premise + Azure pour la seule sauvegarde, argumenté sur les cinq axes imposés |
| [`docs/cicd/runbook.md`](docs/cicd/runbook.md) | installation depuis zéro, déploiement, retour arrière, restauration, rotation des secrets |
| [`docs/cicd/quality-gates.md`](docs/cicd/quality-gates.md) | ce qui bloque une fusion et ce qui informe, et pourquoi |
| [`docs/cicd/ci-usage.md`](docs/cicd/ci-usage.md) | brancher un dépôt de service sur la chaîne |

Détails par couche : [`infra/k8s/README.md`](infra/k8s/README.md),
[`infra/terraform/README.md`](infra/terraform/README.md),
[`infra/ansible/README.md`](infra/ansible/README.md).

## Principe général

1. Chaque service a son propre dépôt, son propre `Dockerfile`, et son
   propre workflow GitHub Actions qui construit et pousse l'image sur
   GHCR.
2. Ce workflow se termine en appelant `deploy.yml` de ce dépôt
   (`workflow_call`), en lui passant le nom du service et le tag d'image.
3. `deploy.yml` déduit le stage de la branche appelante — `main` ou une
   étiquette donnent `prod`, tout le reste `dev` — puis lance le rollout
   dans le namespace `g4-<stage>` via `scripts/k8s-apply.sh`, exécuté en
   SSH sur l'hôte.
4. Les services se joignent par leur nom DNS interne : `g4-api`, `g4-db`,
   `g4-kafka`. Le tiret n'est pas un détail de style — un underscore est
   interdit dans un nom DNS (RFC 1123).
5. Portabilité : rien n'est câblé sur le serveur de l'école. Les mêmes
   rôles Ansible provisionnent une autre machine en changeant
   d'inventaire (`infra/ansible/inventories/`), et les mêmes manifestes
   tournent sur n'importe quel cluster Kubernetes.

## Ajouter un nouveau service

1. Créer `infra/k8s/base/<service>/` sur le modèle des composants
   existants (voir `infra/k8s/base/api/`), et l'ajouter aux `resources:`
   de `infra/k8s/base/kustomization.yaml`.
2. Ajouter les variables nécessaires dans `envs/k3s.env.example`, puis
   dans le secret `ENV_FILE_CONTENTS` des deux Environments GitHub.
3. Dans le dépôt du service, ajouter le workflow qui construit l'image
   puis appelle `deploy.yml` — modèle complet dans
   [`docs/cicd/ci-usage.md`](docs/cicd/ci-usage.md).

## Sauvegarde chiffrée

Un CronJob Kubernetes envoie chaque nuit un `pg_dump` chiffré par restic
vers Azure Blob. Chaque lundi, `backup-restore-drill.yml` restaure le
dernier instantané dans une base jetable **sur un runner GitHub** — sans
toucher au serveur de l'école — et vérifie que les tables et les
hypertables TimescaleDB sont bien là. C'est ce qui prouve que les
sauvegardes fonctionnent, plutôt que de prouver qu'un fichier arrive dans
Azure.

restic étant compatible Azure Blob, S3/OVH/AWS, SFTP et disque local, la
cible se change avec la seule variable `RESTIC_REPOSITORY` : sortir
d'Azure ne demanderait aucune réécriture.

Procédure de restauration manuelle :
[`docs/cicd/runbook.md`](docs/cicd/runbook.md), section 4.
