# Comprendre le déploiement k3s — l'essentiel pour le défendre

Ce document n'explique pas Kubernetes. Il explique **les huit notions
utilisées dans ce dépôt**, chacune reliée au fichier concerné, avec ce
qu'elle règle comme problème. C'est le minimum pour lire `infra/k8s/`
sans se perdre, et pour répondre en soutenance.

---

## L'idée en une phrase

On décrit **l'état voulu** dans des fichiers YAML (« je veux deux
exemplaires de l'API, joignables sur le port 3000, avec ces variables
d'environnement »), et Kubernetes se charge en permanence de faire
correspondre la réalité à cette description.

C'est la différence de fond avec `docker compose up`, qui **exécute une
action** et s'arrête là. Si un conteneur meurt à 3 h du matin, Compose ne
fait rien de plus que ce que dit sa politique de redémarrage ;
Kubernetes, lui, compare en boucle « 2 exemplaires voulus » à « 1
exemplaire vivant » et relance ce qui manque.

## k3s, ce n'est pas Kubernetes complet

**k3s** est une distribution de Kubernetes en un seul binaire d'environ
70 Mo, conçue pour une machine unique. Elle apporte d'office deux choses
qu'on utilise sans les avoir installées :

- **Traefik**, qui reçoit le trafic HTTP du port 80 et l'aiguille vers le
  bon service (`ingressClassName: traefik` dans nos manifestes) ;
- **local-path**, qui fabrique un dossier sur le disque du serveur quand
  un composant réclame du stockage (`storageClassName: local-path`).

Sur un vrai cluster de production, ces deux briques s'installent et se
configurent séparément. Ici, elles sont fournies : on les utilise telles
quelles. C'est ce qui rend le choix tenable à une personne.

---

## Les huit objets qu'on utilise

### 1. Namespace — la cloison entre dev et prod

`infra/k8s/overlays/{dev,prod}/namespace.yaml`

Un namespace est un compartiment étanche à l'intérieur du cluster. On en
a deux, `g4-dev` et `g4-prod`. Deux objets de même nom dans deux
namespaces différents sont deux objets sans aucun rapport : la base de
`g4-dev` et celle de `g4-prod` s'appellent toutes deux `g4-db` et ne se
voient pas.

> **C'est la raison principale du passage à k3s.** Sur une seule machine
> partagée, isoler dev et prod avec Compose demandait de préfixer à la
> main chaque réseau, chaque volume et chaque nom de conteneur — un
> oubli suffisait à ce que dev écrive dans la base de prod. Ici,
> l'isolation est structurelle, pas conventionnelle.

### 2. Deployment — « je veux N exemplaires de ce conteneur »

`infra/k8s/base/api/deployment.yaml`, et de même pour dashboard, etl,
messager-consumer.

C'est l'équivalent d'un service dans un `docker-compose.yml`, avec deux
ajouts :

- **`replicas`** : combien d'exemplaires tourner. `1` en dev, `2` en prod
  pour l'API et le dashboard.
- **`strategy: RollingUpdate` avec `maxUnavailable: 0`** : au moment de
  déployer une nouvelle version, le nouvel exemplaire est démarré et
  déclaré prêt **avant** que l'ancien soit arrêté. Concrètement,
  déploiement sans coupure.

Kubernetes garde aussi l'historique des versions déployées — c'est ce qui
rend possible `kubectl rollout undo` (voir plus bas).

### 3. StatefulSet — comme un Deployment, mais pour ce qui a des données

`infra/k8s/base/db/statefulset.yaml`, `infra/k8s/base/kafka/statefulset.yaml`

La base et Kafka ne sont pas interchangeables comme l'est un exemplaire
d'API : ils possèdent un disque. Un StatefulSet garantit un nom stable
(`g4-db-0`) et **rattache toujours le même volume au même exemplaire**.
Un Deployment pourrait recréer le pod ailleurs et perdre le lien avec les
données.

Règle simple : **avec des données sur disque → StatefulSet ; sans →
Deployment.**

### 4. Service — le nom DNS interne, stable

`infra/k8s/base/api/service.yaml`, etc.

Un pod a une adresse IP qui change à chaque redémarrage. Un Service est
un nom fixe qui pointe toujours vers les pods vivants du composant :
l'API joint la base en écrivant `g4-db`, sans jamais connaître son IP.
Quand il y a deux exemplaires d'API, le Service répartit aussi le trafic
entre eux.

> ⚠ **Le tiret n'est pas cosmétique.** `g4-db`, pas `g4_db`. Un
> underscore est interdit dans un nom DNS (RFC 1123). Les alias réseau de
> Docker le toléraient, les Services Kubernetes non. C'est la seule
> adaptation à faire en reprenant un `.env` d'un déploiement Compose —
> voir `envs/k3s.env.example`.

### 5. Ingress — la porte d'entrée depuis l'extérieur

`infra/k8s/base/ingress/ingress.yaml`

Un Service n'est joignable que depuis l'intérieur du cluster. L'Ingress
dit à Traefik : « ce qui arrive sur `enervision.local/api` va vers le
Service `g4-api`, le reste vers `g4-dashboard` ». C'est le remplaçant du
`ports:` de Compose, en une seule porte d'entrée pour tous les services.

Grafana n'a volontairement pas d'Ingress : c'est un outil
d'administration, on y accède par tunnel (`kubectl port-forward`) plutôt
qu'en le publiant sur Internet.

### 6. ConfigMap et Secret — la configuration, hors des images

Deux boîtes de paires clé/valeur montées dans les conteneurs. La
différence est d'intention : un Secret contient ce qui ne doit pas être
lu par n'importe qui.

On en a trois, et **aucune n'est dans les manifestes** :

| Objet | Contenu | Créé par |
|---|---|---|
| Secret `g4-env` | le `.env` complet du stage | `scripts/k8s-apply.sh`, depuis le secret GitHub `ENV_FILE_CONTENTS` |
| ConfigMap `g4-db-initdb` | `db/init/*.sql` | idem, depuis les fichiers du dépôt |
| ConfigMap `g4-backup-script` | `scripts/db-backup-to-azure.sh` | idem |

Le Secret parce qu'un mot de passe n'a rien à faire dans Git. Les deux
ConfigMaps pour ne pas recopier le SQL et le script dans des manifestes :
il n'existe qu'une seule version de chacun.

Les conteneurs les consomment avec `envFrom: secretRef: g4-env` — toutes
les clés du `.env` deviennent des variables d'environnement, exactement
comme `env_file:` en Compose.

### 7. Probes — comment Kubernetes sait qu'un composant va bien

Dans `infra/k8s/base/api/deployment.yaml` :

- **`readinessProbe`** : « ce pod peut-il recevoir du trafic ? » Tant
  qu'elle échoue, le Service ne lui envoie rien. C'est elle qui rend le
  déploiement sans coupure possible.
- **`livenessProbe`** : « ce pod est-il encore vivant ? » Si elle échoue
  plusieurs fois, Kubernetes tue le conteneur et le relance.

Les deux interrogent `/health`, la route que l'API expose déjà. C'est
aussi pour ça que cette route compte : elle sert aux sondes, au test de
fumée après déploiement, et au contrôle de charge k6.

### 8. CronJob — une tâche planifiée

`infra/k8s/base/backup/cronjob.yaml`

L'équivalent d'une ligne de crontab, mais dans le cluster : mêmes
secrets, même réseau, journaux consultables avec `kubectl logs`. Le nôtre
sauvegarde la base chaque nuit vers Azure.

Il utilise deux conteneurs à la suite parce qu'**aucune image ne fournit
à la fois `pg_dump` et `restic`** : un `initContainer` produit le dump
avec l'image TimescaleDB, puis le conteneur principal le chiffre et
l'envoie avec l'image restic. Les deux partagent un dossier temporaire
(`emptyDir`).

En dev, il est livré `suspend: true` : on ne sauvegarde pas des données
jetables.

---

## `base/` et `overlays/` : pourquoi deux niveaux

Sans ce découpage, il faudrait deux copies complètes des manifestes, une
par stage, et toute correction devrait être faite deux fois — avec le
risque classique de n'en corriger qu'une.

- **`base/`** décrit ce qui est commun. Aucun namespace, aucun nom
  d'hôte, aucun secret.
- **`overlays/dev/`** et **`overlays/prod/`** ne contiennent que les
  différences.

C'est l'outil `kustomize` (intégré à `kubectl`) qui fusionne les deux. Ce
que les surcouches changent réellement :

| | dev | prod |
|---|---|---|
| namespace | `g4-dev` | `g4-prod` |
| replicas api / dashboard | 1 | 2 |
| nom d'hôte | `dev.enervision.local` | `enervision.local` |
| sauvegarde | suspendue | active, 02:00 |
| disque base | 10 Gi | 20 Gi |

Voir le résultat fusionné, sans rien déployer :

```bash
kustomize build infra/k8s/overlays/prod
```

---

## Le trajet complet d'un déploiement

1. Vous poussez sur `main` dans `enervision-api`.
2. Son workflow construit l'image et la pousse sur GHCR avec le tag du
   commit.
3. Il appelle `deploy.yml` de ce dépôt, qui déduit `stage = prod`.
4. `deploy-k8s.yml` tourne sur le runner self-hosted, copie le dépôt sur
   le serveur en SSH, et y lance `scripts/k8s-apply.sh prod api <image>`.
5. Le script crée le Secret et les ConfigMaps, écrit le tag de l'image
   dans la surcouche (`kustomize edit set image`), puis applique tout
   (`kubectl apply -k`).
6. Kubernetes constate l'écart entre l'état voulu et l'état réel, démarre
   un pod avec la nouvelle image, attend que sa `readinessProbe` passe,
   bascule le trafic, arrête l'ancien.
7. Le script attend la fin (`kubectl rollout status`) et interroge
   `/health`. Si l'un des deux échoue, le job GitHub est rouge.

**Tout ce que fait la CI, `scripts/k8s-apply.sh` le fait aussi à la
main.** Il n'y a pas de séquence de déploiement cachée dans un workflow :
c'est le même script, ce qui évite le « ça marche en CI mais pas à la
main ».

---

## Les commandes qui suffisent au quotidien

```bash
kubectl -n g4-prod get pods              # qu'est-ce qui tourne
kubectl -n g4-prod get pods -w           # ... en direct pendant un déploiement
kubectl -n g4-prod logs -f deployment/g4-api
kubectl -n g4-prod describe pod <pod>    # pourquoi il ne démarre pas
kubectl -n g4-prod rollout undo deployment/g4-api    # revenir en arrière
kubectl -n g4-prod rollout status deployment/g4-api
kubectl -n g4-prod port-forward svc/g4-grafana 3000:3000
kubectl -n g4-prod exec -it g4-db-0 -- psql -U g4_app g4_db
```

`describe` est celle qui répond le plus souvent : elle affiche en bas la
liste des événements, avec la vraie raison d'un pod bloqué.

**Les trois pannes qu'on rencontre réellement :**

| État | Ce que ça veut dire |
|---|---|
| `ImagePullBackOff` | l'image n'existe pas sur GHCR, ou le tag est faux |
| `CreateContainerConfigError` | le Secret `g4-env` manque ou une clé attendue est absente |
| `Pending` | pas de place : disque plein pour le volume réclamé |

---

## Ce qu'on n'a pas fait, et pourquoi

Dire ce qu'on a écarté vaut mieux que de laisser le jury le trouver.

- **Pas de haute disponibilité.** Un seul nœud : si la machine tombe,
  tout tombe. C'est assumé — la réponse est la sauvegarde hors site et
  son exercice de restauration hebdomadaire, pas un second serveur qu'on
  n'a pas.
- **Pas de découverte automatique des cibles de supervision.** Prometheus
  sait lister seul les pods d'un cluster, mais cela demande un compte de
  service et des droits RBAC. Trois adresses écrites en dur suffisent
  pour six composants connus d'avance, et se relisent d'un coup d'œil.
- **Pas de HorizontalPodAutoscaler.** La charge est constante et connue :
  un collecteur à intervalle fixe, quelques utilisateurs. Mettre en place
  de l'autoscaling répondrait à un problème qu'on n'a pas.
- **Pas de Helm.** Une couche de gabarits en plus, pour six composants
  qu'on maîtrise. `kustomize` est déjà dans `kubectl`.
- **Kafka en un seul nœud**, facteur de réplication 1. La perte du volume
  perd les messages non consommés. Acceptable : la donnée de référence
  est dans PostgreSQL, Kafka n'est qu'un tampon de transport.

---

## Questions probables en soutenance

**« Pourquoi Kubernetes pour six conteneurs sur une machine ? »**
Pour l'isolation entre dev et prod sur un serveur partagé, et pour le
retour arrière. Avec Compose, séparer les deux stages reposait sur un
préfixage manuel de chaque réseau, volume et nom de conteneur : un oubli
et dev écrit dans la base de prod. Le namespace rend cette faute
impossible. Et `kubectl rollout undo` restaure la version précédente sans
reconstruire d'image ni retrouver un tag.

**« Pourquoi k3s et pas Kubernetes complet ? »**
Un seul binaire, Traefik et le stockage inclus, exploitable par une
personne. Kubernetes complet aurait demandé d'installer et de maintenir
un plan de contrôle qui n'apporte rien sur une machine unique.

**« Que se passe-t-il si un pod plante ? »**
La `livenessProbe` sur `/health` échoue, Kubernetes tue le conteneur et
le relance. Si c'est un déploiement fautif, le nouveau pod ne devient
jamais « prêt », l'ancien continue de servir — `maxUnavailable: 0` — et
`kubectl rollout status` sort en erreur, ce qui met le job GitHub en
rouge.

**« Comment revenez-vous en arrière ? »**
`kubectl rollout undo deployment/g4-api`, en quelques secondes, sans
GitHub ni reconstruction. Attention : cela ne défait pas une migration de
schéma de base — dans ce cas il faut restaurer la sauvegarde
(`runbook.md`, section 4).

**« Où sont vos secrets ? »**
Nulle part dans Git. Ils vivent dans les secrets d'Environment GitHub
(`onprem-dev`, `onprem-prod`), et `scripts/k8s-apply.sh` en fabrique le
Secret Kubernetes au moment du déploiement. Le contenu transite par
l'entrée standard de SSH, jamais en argument de ligne de commande — un
argument serait visible dans le `ps` du serveur.

**« Comment ajoutez-vous une machine ? »**
`curl -sfL https://get.k3s.io | K3S_URL=… K3S_TOKEN=… sh -` sur la
nouvelle machine, puis une ligne dans l'inventaire Ansible pour qu'elle
reçoive aussi le durcissement. Aucun manifeste ne présuppose un nœud
unique.

## Voir aussi

- `architecture.md` — les schémas
- `infra-decision.md` — pourquoi cette infrastructure plutôt qu'AWS
- `runbook.md` — les procédures pas à pas
