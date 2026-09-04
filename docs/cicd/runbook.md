# Runbook — exploitation d'EnerVision

Procédures opérationnelles : installer depuis zéro, déployer, revenir en
arrière, restaurer, tourner un secret. Chaque section est autonome et
suppose seulement un accès SSH au serveur et les droits GitHub sur le
dépôt.

> Convention : `<stage>` vaut `dev` ou `prod`. Le namespace Kubernetes
> correspondant est `g4-<stage>`, l'Environment GitHub `onprem-<stage>`.

---

## 1. Installation depuis zéro

Ordre imposé — chaque étape produit ce dont la suivante a besoin.

### 1.1 Azure : état Terraform, puis stockage des sauvegardes

```bash
cd infra/terraform/bootstrap
cp terraform.tfvars.example terraform.tfvars   # choisir un nom de compte unique
terraform init
terraform apply
terraform output -raw backend_config > ../envs/prod/backend.hcl
```

Le module `bootstrap` est le seul dont l'état reste local : il ne peut
pas se stocker dans une ressource qu'il n'a pas encore créée. Conserver
son `terraform.tfstate` hors du dépôt.

Puis l'environnement de production — le seul : **il n'existe pas de
stockage de sauvegarde pour dev.** Sauvegarder des données de
développement, jetables par définition, coûterait un compte Azure et une
rétention pour rien. Le CronJob du namespace `g4-dev` est livré suspendu
(`infra/k8s/overlays/dev/kustomization.yaml`).

```bash
cd infra/terraform/envs/prod
cp terraform.tfvars.example terraform.tfvars
# adapter backend.hcl : la clé doit être "prod/terraform.tfstate"
terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

Relever les sorties — elles alimentent les secrets GitHub de l'étape 1.3 :

```bash
terraform output storage_account_name
terraform output -raw storage_account_key   # sensible
terraform output restic_repository
```

> Terraform ne gère que l'Azure des sauvegardes. La protection de
> branche GitHub se règle à la main — voir la section 1.4.

### 1.2 Serveur : cluster k3s

Générer d'abord la paire de clés de déploiement, depuis un poste de
confiance :

```bash
ssh-keygen -t ed25519 -f ~/.ssh/g4_deploy -C "g4-deploy" -N ""
```

Puis, depuis le dépôt :

```bash
cd infra/ansible
pip install ansible-core
ansible-galaxy collection install -r requirements.yml

export G4_SSH_HOST=<adresse du serveur>
export G4_SSH_USER=enervision-g4
export G4_SSH_KEY=~/.ssh/g4_deploy

# Vérifier ce qui va se passer avant de le faire :
ansible-playbook -i inventories/onprem.ini playbooks/bootstrap-cluster.yml --check --diff
ansible-playbook -i inventories/onprem.ini playbooks/bootstrap-cluster.yml
```

`bootstrap-cluster.yml` installe k3s, `kubectl`, `kustomize`, crée les
namespaces `g4-dev` et `g4-prod` et pose le kubeconfig pour l'utilisateur
de déploiement. Il ne touche **ni au pare-feu, ni à la configuration
SSH** : c'est délibéré, pour qu'un premier passage ne puisse pas couper
l'accès à la machine.

Vérifier :

```bash
ssh $G4_SSH_USER@$G4_SSH_HOST 'kubectl get nodes && kubectl get ns'
```

Le reste du provisionnement — durcissement, runners, outillage de
sauvegarde — vient ensuite :

```bash
export RESTIC_REPOSITORY=... RESTIC_PASSWORD=... \
       AZURE_ACCOUNT_NAME=... AZURE_ACCOUNT_KEY=... \
       POSTGRES_USER=... POSTGRES_PASSWORD=... POSTGRES_DB=...
ansible-playbook -i inventories/onprem.ini playbooks/site.yml
```

Les runners GitHub self-hosted ne sont pas gérés par Ansible : ils se
montent une fois à la main depuis `infra/runners/` (voir son README).
Les envelopper dans un rôle n'aurait fait que déguiser un
`docker compose up -d`.

### 1.3 GitHub : Environments et secrets

Créer **deux** Environments dans `Settings > Environments` :
`onprem-dev` et `onprem-prod`. Chacun porte ses propres valeurs :

| Secret | Contenu |
|---|---|
| `ENV_FILE_CONTENTS` | le `.env` complet du stage — partir de `envs/k3s.env.example` |
| `SSH_HOST` | adresse du serveur joignable depuis le runner |
| `SSH_USER` | utilisateur de déploiement |
| `SSH_PRIVATE_KEY` | contenu de `~/.ssh/g4_deploy` |
| `SSH_PORT` | facultatif, `22` par défaut |
| `RESTIC_REPOSITORY` `RESTIC_PASSWORD` | dépôt restic du stage (drill de restauration) |
| `AZURE_ACCOUNT_NAME` `AZURE_ACCOUNT_KEY` | sorties Terraform de l'étape 1.1 |

> ⚠ `ENV_FILE_CONTENTS` du chemin k3s utilise des noms d'hôtes avec
> **tiret** (`g4-db`, `g4-kafka`, `g4-api`), pas avec underscore. Un
> underscore est interdit dans un nom DNS : les alias réseau Docker le
> tolèrent, les Services Kubernetes non. Voir `envs/k3s.env.example`.

Vérifier ensuite que les runners self-hosted apparaissent bien avec les
étiquettes `dev` et `prod` dans `Settings > Actions > Runners`.

### 1.4 Protection de branche (à faire une fois)

`Settings > Branches > Add branch ruleset` (ou *Branch protection rule*),
pour `main` **et** pour `develop` :

| Case | Valeur |
|---|---|
| Require a pull request before merging | ✅ |
| └ Require approvals | **0** — la PR est obligatoire, le relecteur non |
| └ Dismiss stale approvals | ✅ |
| Require status checks to pass | ✅ |
| └ Require branches to be up to date | ✅ |
| └ Checks requis | `build`, `test`, `security-scan` |
| Require conversation resolution | ✅ |
| Allow force pushes | ❌ |
| Allow deletions | ❌ |
| Do not allow bypassing (admins) | ❌ — porte de sortie assumée |

Ce n'est pas géré par Terraform : six cases cochées une fois ne
justifiaient pas un fournisseur supplémentaire et un jeton GitHub à faire
tourner. Le raisonnement complet est dans `quality-gates.md`.

### 1.5 Premier déploiement

```bash
# Depuis GitHub : Actions > "Deploy dev" > Run workflow
# ou, à la main sur le serveur :
export ENV_FILE_CONTENTS="$(cat mon-env-dev)"
cd /opt/g4/repo && ./scripts/k8s-apply.sh dev
```

---

## 2. Déploiement courant

**Un service** (déclenché automatiquement par son propre dépôt, qui
construit et pousse l'image puis appelle `deploy.yml`) :

```
push sur develop  →  namespace g4-dev
push sur main / étiquette  →  namespace g4-prod
```

**Les composants d'infrastructure** que ce dépôt possède — base, Kafka,
supervision, CronJob de sauvegarde — se déploient par « Deploy dev » et
« Deploy prod », déclenchés par une poussée touchant `infra/k8s/**`,
`db/init/**` ou `scripts/**`.

**À la main**, exactement la même séquence que la CI :

```bash
ssh <serveur>
cd /opt/g4/repo
export ENV_FILE_CONTENTS="$(cat /chemin/vers/env)"

./scripts/k8s-apply.sh prod                              # tout le stage
./scripts/k8s-apply.sh prod api ghcr.io/.../api:abc123   # un seul service
```

Suivre ce qui se passe :

```bash
kubectl -n g4-prod get pods -w
kubectl -n g4-prod logs -f deployment/g4-api
kubectl -n g4-prod describe pod <pod>       # si un pod reste Pending
```

---

## 3. Retour arrière

Kubernetes garde l'historique des révisions : le retour arrière ne
dépend ni de GitHub, ni d'une image reconstruite.

```bash
kubectl -n g4-prod rollout history deployment/g4-api
kubectl -n g4-prod rollout undo deployment/g4-api             # révision précédente
kubectl -n g4-prod rollout undo deployment/g4-api --to-revision=3
kubectl -n g4-prod rollout status deployment/g4-api
```

Pour figer durablement une version antérieure — sinon le prochain
déploiement réappliquera la dernière image connue :

```bash
cd /opt/g4/repo/infra/k8s/overlays/prod
kustomize edit set image ghcr.io/enervision-g4/enervision-api=ghcr.io/enervision-g4/enervision-api:<tag-connu-bon>
kubectl apply -k .
```

> `rollout undo` ne concerne que les Deployments et StatefulSets. Il ne
> **défait pas** une migration de schéma de base de données : si le
> déploiement fautif a modifié la structure, il faut restaurer la base
> (section 4).

---

## 4. Restauration de la base

### 4.1 Ce qui est vérifié automatiquement

`backup-restore-drill.yml` tourne chaque lundi à 06:00 UTC sur un runner
**GitHub**, jamais sur le serveur de l'école. Il récupère le dernier
instantané depuis Azure, le restaure dans une base TimescaleDB jetable,
et vérifie que toutes les tables de `db/init/002_create_tables.sql` sont
présentes et que les hypertables sont reconstruites.

Ce choix de runner est le cœur de l'exercice : le scénario qui compte est
celui où le serveur est perdu. Un drill qui aurait besoin de ce serveur
ne prouverait rien.

Lancer un exercice à la demande : `Actions > Backup restore drill > Run
workflow`.

**Si le drill échoue, les sauvegardes ne valent rien.** Traiter en
priorité, avant tout autre travail.

### 4.2 Restauration manuelle, pendant un incident

> ⚠ `--clean --if-exists` **écrase** la base cible. Vérifier deux fois le
> `PGHOST` avant de lancer.

**Étape 1 — arrêter ce qui écrit dans la base.** Sinon la restauration se
bat avec les écritures en cours :

```bash
kubectl -n g4-prod scale deployment/g4-api deployment/g4-etl \
        deployment/g4-messager-consumer --replicas=0
```

**Étape 2 — choisir l'instantané.**

```bash
export RESTIC_REPOSITORY=azure:g4-backups:/restic-prod
export RESTIC_PASSWORD=... AZURE_ACCOUNT_NAME=... AZURE_ACCOUNT_KEY=...
restic snapshots --tag g4-prod
```

**Étape 3 — restaurer.** Depuis le serveur, en exposant la base :

```bash
kubectl -n g4-prod port-forward statefulset/g4-db 5432:5432 &

cd /opt/g4/repo
export PGHOST=127.0.0.1 PGPORT=5432 \
       PGUSER=g4_app PGPASSWORD=... PGDATABASE=g4_db
export SNAPSHOT=latest        # ou l'identifiant relevé à l'étape 2
export BACKUP_TAG=g4-prod
./scripts/db-restore-drill.sh
```

Le script fait la séquence complète : récupération depuis Azure,
`timescaledb_pre_restore()`, `pg_restore`, `timescaledb_post_restore()`,
puis contrôle des tables et des hypertables.

**Étape 4 — redémarrer.**

```bash
kubectl -n g4-prod scale deployment/g4-api --replicas=2
kubectl -n g4-prod scale deployment/g4-etl deployment/g4-messager-consumer --replicas=1
kubectl -n g4-prod rollout status deployment/g4-api
```

**Étape 5 — vérifier** que `/health` répond et que le dashboard affiche
des données récentes.

### 4.3 Restaurer ailleurs — serveur perdu

Le même script vise n'importe quelle base PostgreSQL/TimescaleDB
joignable : il suffit de changer `PGHOST`. Depuis n'importe quel poste
ayant `restic` et `postgresql-client-16` :

```bash
docker run -d --name g4-recovery -p 5432:5432 \
  -e POSTGRES_USER=g4_app -e POSTGRES_PASSWORD=<mdp> -e POSTGRES_DB=g4_db \
  timescale/timescaledb:2.17.2-pg16

export PGHOST=127.0.0.1 PGUSER=g4_app PGPASSWORD=<mdp> PGDATABASE=g4_db
export RESTIC_REPOSITORY=... RESTIC_PASSWORD=... \
       AZURE_ACCOUNT_NAME=... AZURE_ACCOUNT_KEY=...
./scripts/db-restore-drill.sh
```

Pour remonter l'application complète sur une autre machine :

```bash
export G4_AZURE_HOST=<nouvelle machine> G4_AZURE_USER=... G4_AZURE_KEY=...
ansible-playbook -i inventories/azure.ini playbooks/site.yml
```

Les rôles sont identiques — seul l'inventaire change. C'est la
démonstration concrète de la portabilité affirmée dans
`infra-decision.md`.

### 4.4 Pourquoi `pg_dump` et pas `pg_basebackup`

`pg_basebackup` produit une copie **physique** des fichiers du serveur.
Elle est plus rapide sur une grosse base et permet la restauration à un
instant précis, mais elle impose que la cible ait la même version majeure
de PostgreSQL, la même architecture et les mêmes extensions installées au
même endroit.

`pg_dump -Fc` produit un dump **logique**, rechargeable dans un serveur
de version différente, sur une autre machine, avec d'autres rôles — c'est
exactement ce que demandent nos deux cas d'usage : la base jetable du
drill hebdomadaire, et une reprise sur une machine improvisée pendant un
incident. Le format `custom` reste compressé et permet de restaurer une
table isolée.

Le volume de données ne justifie pas la complexité de `pg_basebackup`. Ce
serait à revoir si la base atteignait plusieurs dizaines de gigaoctets,
ou si une exigence de perte de données maximale de quelques minutes
apparaissait — il faudrait alors du WAL archiving, pas un dump quotidien.

### 4.5 Le point TimescaleDB à ne pas manquer

Un `pg_restore` d'une base TimescaleDB **sans** encadrement recharge les
hypertables comme des tables ordinaires : les données sont là, le
catalogue Timescale ne les connaît plus, et la base est silencieusement
cassée. La séquence obligatoire est :

```sql
CREATE EXTENSION IF NOT EXISTS timescaledb;
SELECT timescaledb_pre_restore();
-- pg_restore ici
SELECT timescaledb_post_restore();
```

`scripts/db-restore-drill.sh` la respecte, y compris quand `pg_restore`
échoue — sans `post_restore`, la base resterait bloquée en mode
restauration.

---

## 5. Rotation d'un secret

### 5.1 Clé du compte de stockage Azure

```bash
az storage account keys renew \
  --resource-group g4-backup-prod \
  --account-name <compte> \
  --key primary
```

Reporter la nouvelle valeur dans `AZURE_ACCOUNT_KEY` (Environment
`onprem-prod`), puis rejouer le rôle qui écrit `/etc/g4/backup.env` :

```bash
export AZURE_ACCOUNT_KEY=<nouvelle valeur>   # + les autres variables
ansible-playbook -i inventories/onprem.ini playbooks/backup.yml
```

Relancer enfin « Deploy prod » pour régénérer le secret Kubernetes
`g4-env` — le CronJob de sauvegarde le lit à chaque exécution.

Vérifier : `Actions > Backup restore drill > Run workflow`.

### 5.2 Passphrase restic (`RESTIC_PASSWORD`)

> ⚠ **Non rotative au sens habituel.** C'est la clé de chiffrement du
> dépôt : la changer ne rechiffre pas les instantanés existants. La
> perdre rend **toutes** les sauvegardes définitivement illisibles.

`restic key add` ajoute une clé au dépôt sans invalider l'ancienne. Pour
repartir sur une passphrase neuve, la seule voie propre est un nouveau
dépôt (`RESTIC_REPOSITORY` avec un chemin différent), en conservant
l'ancien jusqu'à expiration de sa rétention.

### 5.3 Clé SSH de déploiement

```bash
ssh-keygen -t ed25519 -f ~/.ssh/g4_deploy_new -C "g4-deploy" -N ""
```

1. Ajouter la **nouvelle** clé publique sur le serveur, sans retirer
   l'ancienne (`ansible-playbook playbooks/site.yml` avec
   `DEPLOY_PUBKEY` renseigné).
2. Mettre `SSH_PRIVATE_KEY` à jour dans les deux Environments.
3. Lancer un déploiement de vérification.
4. Seulement ensuite, retirer l'ancienne clé de
   `~/.ssh/authorized_keys` sur le serveur.

L'ordre est le point important : retirer avant d'avoir vérifié coupe la
CI et l'accès humain d'un seul geste.

### 5.4 Mot de passe PostgreSQL

Changer le mot de passe dans la base, puis dans `ENV_FILE_CONTENTS` des
deux Environments, puis redéployer. `DATABASE_URL` contient le mot de
passe : ne pas oublier de le mettre à jour dans la même chaîne.

---

## 6. Opérations diverses

### 6.1 Activer le durcissement SSH

Le rôle `hardening` peut couper l'authentification par mot de passe.
Elle est **désactivée par défaut**, et ce n'est pas de la prudence
excessive : une clé mal installée transforme le serveur de l'école en
machine inaccessible, avec un déplacement physique pour seule solution.

Avant d'activer :

```bash
# 1. Vérifier que la connexion par clé fonctionne, sans mot de passe :
ssh -o PasswordAuthentication=no -i ~/.ssh/g4_deploy <user>@<serveur> 'echo OK'

# 2. Garder une seconde session SSH OUVERTE pendant toute l'opération.
```

Puis :

```bash
ansible-playbook -i inventories/onprem.ini playbooks/site.yml \
  -e hardening_disable_password_auth=true
```

Le rôle refuse de continuer si `authorized_keys` est vide. **Tester une
nouvelle connexion depuis la session restée ouverte** avant de la
fermer. En cas de blocage : accès console physique, remettre
`PasswordAuthentication yes` dans `/etc/ssh/sshd_config`, redémarrer
`ssh`.

### 6.2 Exposer l'application sans DNS

Les Ingress utilisent des noms d'hôtes (`dev.enervision.local`,
`enervision.local`) qui supposent des enregistrements DNS. Sans DNS,
deux options.

Pour un test, ajouter dans `/etc/hosts` du poste client :

```
<ip du serveur>  enervision.local dev.enervision.local
```

Grafana n'a volontairement pas d'Ingress — c'est un outil
d'administration, le publier ajouterait une surface d'attaque pour rien.
On y accède par un tunnel :

```bash
kubectl -n g4-prod port-forward svc/g4-grafana 3000:3000
```

Pour un accès durable, remplacer l'Ingress par un Service NodePort — à
ajouter dans la surcouche du stage :

```yaml
# infra/k8s/overlays/prod/nodeport.yaml
apiVersion: v1
kind: Service
metadata:
  name: g4-dashboard-nodeport
spec:
  type: NodePort
  selector:
    app.kubernetes.io/name: dashboard
  ports:
    - port: 80
      targetPort: 80
      nodePort: 30080
```

Ne pas oublier d'ouvrir le port dans `hardening_allowed_tcp_ports`.

### 6.3 Ajouter un nœud au cluster

```bash
# Sur le serveur, relever le jeton :
sudo cat /var/lib/rancher/k3s/server/node-token

# Sur la nouvelle machine :
curl -sfL https://get.k3s.io | K3S_URL=https://<serveur>:6443 \
  K3S_TOKEN=<jeton> sh -
```

Ajouter ensuite l'hôte dans `[k3s_servers]` de l'inventaire pour que le
durcissement et l'outillage de sauvegarde s'y appliquent aussi.

### 6.4 Sauvegarde immédiate avant une opération risquée

```bash
kubectl -n g4-prod create job --from=cronjob/g4-db-backup backup-manuel-$(date +%s)
kubectl -n g4-prod logs -f job/backup-manuel-<...>
```

### 6.5 Kafka en nœud unique

Le broker tourne à un exemplaire, facteur de réplication 1 : la perte du
volume perd les messages non encore consommés. C'est acceptable ici — les
données de référence sont dans PostgreSQL, Kafka n'est qu'un tampon de
transport. Pour une vraie tolérance de panne il faudrait trois brokers et
un facteur de réplication de 3, ce qui suppose plusieurs nœuds.

---

## 7. Dépannage

| Symptôme | Piste |
|---|---|
| Pod `Pending` sans fin | `kubectl describe pod` — le plus souvent un PVC en attente : le provisionneur `local-path` manque de place. |
| `ImagePullBackOff` | Image absente de GHCR ou privée : le nœud a-t-il des identifiants ? Vérifier le tag exact. |
| `CreateContainerConfigError` | Secret `g4-env` absent ou incomplet — `ENV_FILE_CONTENTS` vide dans l'Environment. |
| Le job de déploiement reste en attente | Aucun runner self-hosted en ligne avec l'étiquette du stage. `Settings > Actions > Runners`. |
| Le drill échoue sur « tables absentes » | Le dump est vide ou tronqué : vérifier les logs du CronJob de sauvegarde des derniers jours. |
| `restic: repository is already locked` | Deux sauvegardes concurrentes. Attendre, puis `restic unlock` si le verrou est orphelin. |
| Grafana affiche « no data » | Vérifier `kubectl -n g4-<stage> get endpoints` : un Service sans endpoint n'est jamais scrapé. |
| `Deploy prod` refuse de partir | Le dernier « Deploy dev » n'est pas vert. Corriger dev, ou relancer avec `skip_dev_gate` en cas d'incident. |

## Voir aussi

- `k8s-primer.md` — comprendre les objets manipulés par ces commandes
- `architecture.md` — vue d'ensemble
- `infra-decision.md` — pourquoi cette infrastructure
- `quality-gates.md` — ce qui bloque une fusion
- `ci-usage.md` — brancher un dépôt de service
