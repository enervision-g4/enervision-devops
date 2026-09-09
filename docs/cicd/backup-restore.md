# Sauvegarde et restauration de la base

Une sauvegarde chiffrée quotidienne vers un dépôt restic, et une
procédure de restauration à exécuter à la main quand il le faut.

## Ce qui tourne

| Quand | Quoi | Où |
|---|---|---|
| tous les jours 02:00 UTC | `backup-db.yml` — `pg_dump` chiffré par restic vers le dépôt distant | runner self-hosted du stage |

La restauration n'est pas automatisée : c'est une opération rare, faite
par une personne qui sait pourquoi elle la fait. La procédure est en bas
de ce document.

> ⚠️ **Conséquence à assumer** : rien ne vérifie périodiquement que les
> sauvegardes sont restaurables. Le seul contrôle automatique est
> `restic check --read-data-subset=5%`, exécuté à chaque sauvegarde —
> il valide l'intégrité du dépôt, pas le fait qu'un `pg_restore` en
> ressorte une base utilisable. Faites la procédure manuelle au moins une
> fois avant la soutenance, pour savoir qu'elle fonctionne.

## Le script

`scripts/db-backup-to-azure.sh` — trois modes, une seule logique :

| Mode | Fait quoi | Utilisé par |
|---|---|---|
| `dump` | `pg_dump` seul | un conteneur qui n'a que le client PostgreSQL |
| `push` | restic seul (chiffrement, envoi, rétention, vérification) | un conteneur qui n'a que restic |
| `all` | les deux à la suite | `backup-db.yml`, et l'exécution manuelle |

Il atteint la base de deux façons. Si `G4_DB_CONTAINER` est défini, il
passe par `docker exec` — c'est le cas du déploiement Compose actuel, où
le port PostgreSQL n'est pas publié sur l'hôte, donc il n'y a rien à
joindre par le réseau. Sinon, connexion TCP classique. Le chiffrement, la
rétention et le dépôt sont identiques dans les deux cas.

## Pourquoi `pg_dump` et pas `pg_basebackup`

`pg_basebackup` produit une copie **physique** des fichiers du serveur.
Plus rapide sur une grosse base, et permet la restauration à un instant
précis — mais impose à la cible la même version majeure de PostgreSQL, la
même architecture et les mêmes extensions au même endroit.

`pg_dump -Fc` produit un dump **logique**, rechargeable dans un serveur
de version différente, sur une autre machine, avec d'autres rôles. C'est
exactement ce que demande une reprise sur une machine improvisée pendant
un incident. Le format `custom` reste compressé et permet de restaurer
une table isolée.

À revoir si la base atteignait plusieurs dizaines de gigaoctets, ou si
une exigence de perte maximale de quelques minutes apparaissait — il
faudrait alors de l'archivage de WAL, pas un dump quotidien.

## Rétention

Appliquée par `restic forget --prune` : **30 quotidiennes, 12
mensuelles**.

Elle n'est délibérément **pas** confiée à une règle de cycle de vie du
fournisseur de stockage. Un dépôt restic est dédupliqué : un blob ancien
peut contenir des morceaux encore référencés par l'instantané d'hier.
Supprimer par âge corromprait le dépôt entier.

## Changer de cible de stockage

Une seule variable, `RESTIC_REPOSITORY` :

| Cible | Valeur | Identifiants attendus |
|---|---|---|
| Azure Blob | `azure:g4-backups:/restic-prod` | `AZURE_ACCOUNT_NAME`, `AZURE_ACCOUNT_KEY` |
| S3 / OVH / MinIO | `s3:https://…/bucket` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` |
| SFTP | `sftp:user@hote:/chemin` | clé SSH |
| Disque local | `/srv/restic` | aucun |

Le script n'exige que les identifiants du type visé : il lit le préfixe
de `RESTIC_REPOSITORY` et n'impose rien d'autre. « Changer de fournisseur
= changer une variable » est donc vrai, et vérifiable.

---

# Restaurer

> ⚠️ La procédure **écrase** la base cible. Vérifier deux fois `PGHOST`.

## ⚠️ Le piège TimescaleDB

Un `pg_restore` sur une base TimescaleDB **sans encadrement** recharge
les hypertables comme des tables ordinaires : les données sont là, le
catalogue Timescale ne les connaît plus, et la base est silencieusement
cassée. Aucune erreur, aucun avertissement — le problème se découvre à la
première requête sur une série temporelle.

La séquence est donc **obligatoire**, et c'est la raison d'être de cette
page :

```sql
CREATE EXTENSION IF NOT EXISTS timescaledb;
SELECT timescaledb_pre_restore();
-- pg_restore ici
SELECT timescaledb_post_restore();
```

`post_restore()` doit être appelé **même si `pg_restore` a échoué**, sinon
la base reste bloquée en mode restauration.

> `scripts/restore.sh`, plus ancien et générique, fait un `pg_restore`
> nu. Il reste utile pour les services non-base (archives de volumes
> Docker) mais **ne doit pas servir à restaurer la base**.

## Procédure

**1. Arrêter ce qui écrit** dans la base, sinon la restauration se bat
avec les écritures en cours.

**2. Choisir l'instantané :**

```bash
export RESTIC_REPOSITORY=azure:g4-backups:/restic-prod
export RESTIC_PASSWORD=... AZURE_ACCOUNT_NAME=... AZURE_ACCOUNT_KEY=...
restic snapshots --tag g4-prod
```

**3. Récupérer le dump :**

```bash
workdir=$(mktemp -d)
restic restore latest --tag g4-prod --target "$workdir"
dump=$(find "$workdir" -name '*.dump' | head -n1)
ls -lh "$dump"
```

**4. Recharger, avec l'encadrement TimescaleDB :**

```bash
export PGHOST=127.0.0.1 PGPORT=5432 \
       PGUSER=g4_app PGPASSWORD=... PGDATABASE=g4_db

psql -v ON_ERROR_STOP=1 -c "CREATE EXTENSION IF NOT EXISTS timescaledb;"
psql -v ON_ERROR_STOP=1 -c "SELECT timescaledb_pre_restore();"

pg_restore --dbname="$PGDATABASE" --no-owner --no-privileges \
           --clean --if-exists --exit-on-error "$dump"
rc=$?

# à lancer même si pg_restore a échoué
psql -v ON_ERROR_STOP=1 -c "SELECT timescaledb_post_restore();"
[ "$rc" -eq 0 ] || echo "pg_restore a échoué (code $rc)"
```

**5. Vérifier** que la base est réellement exploitable — c'est l'étape
qu'on saute et qu'on regrette :

```bash
psql -c "\dt"
psql -c "SELECT hypertable_name, num_chunks
         FROM timescaledb_information.hypertables ORDER BY 1;"
psql -tAc "SELECT count(*) FROM site;"
```

Les hypertables doivent apparaître avec un nombre de chunks non nul. Si
la liste est vide alors que les tables existent, l'encadrement de
l'étape 4 n'a pas été appliqué : la base est cassée, recommencez.

**6. Redémarrer les services**, puis contrôler que l'application voit des
données récentes.

## Restaurer ailleurs, serveur perdu

La même procédure vise n'importe quelle base PostgreSQL/TimescaleDB
joignable. Depuis n'importe quel poste ayant restic et
`postgresql-client-16` :

```bash
docker run -d --name g4-recovery -p 5432:5432 \
  -e POSTGRES_USER=g4_app -e POSTGRES_PASSWORD=<mdp> -e POSTGRES_DB=g4_db \
  timescale/timescaledb:2.17.2-pg16
```

Puis les étapes 2 à 5 avec `PGHOST=127.0.0.1`.

## Secrets attendus

Dans les Environments GitHub `onprem-dev` et `onprem-prod` :

| Secret | Utilisé par |
|---|---|
| `POSTGRES_USER` `POSTGRES_PASSWORD` `POSTGRES_DB` | `backup-db.yml` |
| `RESTIC_REPOSITORY` `RESTIC_PASSWORD` | `backup-db.yml` |
| `AZURE_ACCOUNT_NAME` `AZURE_ACCOUNT_KEY` | idem, si le dépôt est `azure:` |

### Rotation

**Clé du compte de stockage** : la régénérer côté fournisseur, reporter
la nouvelle valeur dans les deux Environments, puis lancer
`Backup DB` à la main pour vérifier.

**`RESTIC_PASSWORD`** : ⚠️ non rotative au sens habituel. C'est la clé de
chiffrement du dépôt — la changer ne rechiffre pas les instantanés
existants, et la perdre rend **toutes** les sauvegardes définitivement
illisibles. `restic key add` ajoute une clé sans invalider l'ancienne ;
pour repartir sur une passphrase neuve, la seule voie propre est un
nouveau dépôt, en conservant l'ancien jusqu'à expiration de sa rétention.
