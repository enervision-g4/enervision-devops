# enervision-devops

Dépôt central de déploiement pour tous les services du projet
(`enervision-api`, `enervision-dashboard`, `enervision-etl`,
`enervision-ml`, et l'infrastructure partagée comme la base de données
et le bus de messages).

Le dépôt `enervision-messager-consumer` est abandonné : les deux consumers
sont écrits dans `enervision-etl` et partagent son image, seule la commande
du conteneur les distingue. Aucun de ces dépôts ne sait déployer
lui-même : chacun build sa propre image, puis appelle un **workflow
réutilisable** défini ici pour effectuer le déploiement réel.

Rien dans cette organisation n'est spécifique à un service en particulier
— la base de données est traitée exactement comme n'importe quel autre
service (`compose/db.yml` a la même forme que `compose/api.yml`,
`compose/etl.yml`, etc.).

## Structure

```
.
├── .github/workflows/deploy.yml   # workflow réutilisable (workflow_call)
├── compose/                       # un fichier Compose par service
│   ├── api.yml
│   ├── consumer-alerting.yml
│   ├── consumer-persistence.yml
│   ├── dashboard.yml
│   ├── db.yml
│   ├── etl.yml
│   ├── kafka.yml              # broker + création des topics
│   └── ml.yml
├── envs/                          # un .env par environnement de déploiement
│   ├── onprem.env.example
│   ├── azure.env.example
│   └── ovh.env.example
├── scripts/
│   ├── bootstrap-network.sh       # créé une fois par environnement
│   ├── backup.sh                  # sauvegarde chiffrée générique (par service)
│   └── restore.sh
└── db/init/                       # scripts d'initialisation SQL (service db uniquement)
```

## Lancer la pile en local

Le workflow de déploiement copie le fichier compose et le `.env` dans un répertoire
dédié, puis lance `docker compose` depuis ce répertoire. En local, les fichiers restent
à leur place et il faut le dire à compose, sinon **deux choses cassent en silence** :

- `-f compose/db.yml` place le répertoire de projet dans `compose/`. Compose y cherche
  le `.env`, ne le trouve pas, et démarre des conteneurs avec toutes les variables
  vides — une base sans mot de passe ni schéma, sans le moindre message d'erreur.
- Le bind mount `./db/init` de `db.yml` se résout alors en `compose/db/init`, qui
  n'existe pas. Docker crée un dossier vide et aucun script d'initialisation ne
  s'exécute : la base démarre sans aucune table.

D'où les deux options, à ne pas oublier :

```bash
docker compose --env-file .env --project-directory . -f compose/db.yml up -d
docker compose --env-file .env --project-directory . -f compose/kafka.yml up -d
docker compose --env-file .env --project-directory . -f compose/etl.yml up -d
docker compose --env-file .env --project-directory . -f compose/consumer-persistence.yml up -d
docker compose --env-file .env --project-directory . -f compose/consumer-alerting.yml up -d
```

Le `.env` local doit porter en plus `STAGE` et `IMAGE`, que le workflow ajoute lui-même
au moment du déploiement.

Aucun avertissement `variable is not set` ne doit apparaître. S'il en reste un, une
variable manque réellement.

## Principe général

1. Chaque service a son propre dépôt, son propre `Dockerfile`, et son
   propre workflow GitHub Actions qui build + push l'image sur le
   registre.
2. Ce workflow se termine en appelant le workflow réutilisable de
   `enervision-devops` (`workflow_call`), en lui passant : le nom du
   service, l'environnement cible, et le tag d'image à déployer.
3. Le workflow réutilisable se connecte en SSH à la machine cible
   (serveur on-premise ou VM cloud) et lance
   `docker compose -f compose/<service>.yml up -d` avec le `.env` de
   l'environnement demandé.
4. Chaque service rejoint le même réseau Docker partagé `g4_net` — c'est
   ce qui leur permet de se parler entre eux (ex: `api` → `db` via le nom
   DNS interne `g4_db`), quel que soit l'environnement.
5. Portabilité : le même `compose/<service>.yml` et le même workflow de
   déploiement tournent sur le on-premise, une VM Azure, un VPS OVH...
   seul le `.env` de l'environnement change (voir `envs/`).

## Ajouter un nouveau service

1. Créer `compose/<service>.yml` sur le modèle des fichiers existants
   (voir `compose/api.yml`).
2. Ajouter les variables nécessaires dans chaque `envs/<env>.env.example`.
3. Dans le dépôt du service, ajouter un workflow qui build/push l'image
   puis appelle `deploy.yml` (voir `enervision-api` en exemple).

## Sauvegarde chiffrée (tous services confondus)

`scripts/backup.sh` et `scripts/restore.sh` sont génériques : ils prennent
le nom du service en paramètre et s'appuient sur `restic` (compatible
Azure Blob, S3/OVH/AWS, SFTP, disque local — la cible se configure via une
seule variable, `RESTIC_REPOSITORY`, dans le `.env` de l'environnement).
Utilisé aujourd'hui pour transférer un instantané chiffré de la base vers
l'environnement Azure où tourne `ml`, mais applicable à n'importe quel
service qui a besoin d'un état à sauvegarder/restaurer.
