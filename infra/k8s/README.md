# infra/k8s

Manifestes Kubernetes du cluster k3s, organisés en base + surcouches
(kustomize).

```
base/                 un répertoire par composant, sans namespace ni secret
  db/ kafka/ api/ dashboard/ etl/ messager-consumer/
  monitoring/         prometheus, grafana, node-exporter
  backup/             CronJob de sauvegarde chiffrée vers Azure
  ingress/            Traefik — le nom d'hôte est fixé par la surcouche
overlays/
  dev/                namespace g4-dev — 1 replica, sauvegarde suspendue
  prod/               namespace g4-prod — 2 replicas sur api et dashboard
```

## Construire et vérifier sans cluster

```bash
kustomize build overlays/dev | kubeconform -strict -summary -ignore-missing-schemas
kubectl apply -k overlays/dev --dry-run=client
```

## Trois ressources ne sont pas dans les manifestes

| Ressource | Origine | Pourquoi pas ici |
|---|---|---|
| Secret `g4-env` | `ENV_FILE_CONTENTS` de l'Environment GitHub | un secret n'a rien à faire dans Git |
| ConfigMap `g4-db-initdb` | `db/init/*.sql` | garder une source unique pour le SQL, lisible hors des manifestes |
| ConfigMap `g4-backup-script` | `scripts/db-backup-to-azure.sh` | même raison : une seule logique de sauvegarde |

Les trois sont créées par `scripts/k8s-apply.sh`, qui est le point
d'entrée unique du déploiement — celui qu'utilisent la CI **et** un
humain sur le serveur.

```bash
export ENV_FILE_CONTENTS="$(cat mon-env)"
./scripts/k8s-apply.sh dev
./scripts/k8s-apply.sh prod api ghcr.io/enervision-g4/enervision-api:abc123
```

## Deux points de conception à connaître

**Les noms d'hôtes internes prennent un tiret.** `g4-db`, `g4-kafka`,
`g4-api` — pas `g4_db`. Un underscore est interdit dans un nom DNS
(RFC 1123). Un `.env` repris d'un déploiement Docker Compose, où ces
noms étaient des alias réseau tolérant l'underscore, doit être adapté :
voir `envs/k3s.env.example`.

**Grafana n'a pas d'Ingress.** C'est un outil d'administration : on y
accède par un tunnel, pas par Internet.

```bash
kubectl -n g4-prod port-forward svc/g4-grafana 3000:3000
```

**Le RBAC de la supervision est namespacé** (`Role`, pas `ClusterRole`).
Le Prometheus de `g4-dev` ne peut rien lire de `g4-prod`, et déployer la
même base dans deux namespaces ne provoque aucune collision de noms
d'objets globaux. Détail dans `base/monitoring/rbac.yaml`.

Pas familier avec Kubernetes ? `docs/cicd/k8s-primer.md` explique les
huit notions utilisées ici, fichier par fichier.

Voir aussi `docs/cicd/architecture.md` et `docs/cicd/runbook.md`.
