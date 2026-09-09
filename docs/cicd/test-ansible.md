# Tester le provisionnement Ansible

Objectif : provisionner une machine jetable, puis **vérifier** que ce qui
a été installé fait ce que le playbook prétend. Pas seulement « le
playbook est vert », mais « restic est là, il parle bien à Azure, le
fichier d'identifiants est en 0600, et une sauvegarde passe pour de
vrai ».

Comptez **30 minutes** la première fois.

---

## 0. Ce que ce test couvre

| Élément | Testé | Comment |
|---|---|---|
| Syntaxe et bonnes pratiques | ✅ sans machine | §2 |
| Connexion et élévation | ✅ | §3, §4 |
| Installation des paquets et de restic | ✅ | §5, §6 |
| Vérification du backend restic | ✅ | §6 — le contrôle qui compte |
| Idempotence | ✅ | §7 |
| Sauvegarde réelle | ✅ | §8 |
| Portabilité vers une autre machine | ✅ | §9 |
| Restauration | ❌ manuelle — `backup-restore.md` |

> Cette branche installe `scripts/db-backup-to-azure.sh`, qui arrive avec
> `feature/db-backup-restore`. Fusionnez-la **avant**, ou testez depuis
> une copie de travail qui contient les deux.

---

## 1. Préparer la machine cible — 10 min

Une VM Ubuntu suffit (2 vCPU, 2 Go). Prenez un **instantané** avant de
commencer : vous voudrez recommencer depuis zéro pour vérifier
l'idempotence sur une machine vierge.

Le compte utilisé doit être **membre du groupe `sudo`** et joignable par
clé :

```bash
# depuis votre poste
ssh-keygen -t ed25519 -f ~/.ssh/g4_test -C g4-test -N ""
ssh-copy-id -i ~/.ssh/g4_test.pub <user>@<VM_IP>
ssh -o PasswordAuthentication=no -i ~/.ssh/g4_test <user>@<VM_IP> 'echo OK'
```

### ⚠️ Vérifier quel `sudo` tourne, tout de suite

```bash
ssh -i ~/.ssh/g4_test <user>@<VM_IP> 'sudo --version | head -1'
```

Si la réponse commence par **`sudo-rs`**, Ansible ne saura pas piloter
l'invite de mot de passe : il attendra une invite qui ne vient jamais et
sortira sur `Timeout waiting for privilege escalation prompt`. Ce n'est
pas un problème de configuration, c'est une incompatibilité entre le
plugin `become` d'Ansible et cette réimplémentation.

Installez GNU sudo sur la VM avant d'aller plus loin, ou le §5 échouera
sans rapport apparent avec le playbook.

---

## 2. Vérifications hors ligne — 3 min

À faire avant de toucher à la machine.

```bash
cd infra/ansible
pip install ansible-core ansible-lint

ansible-lint --profile production .
ansible-playbook site.yml --syntax-check
```

Attendu : `Profile 'production' was required, and it passed.`

> Ni `--syntax-check` ni `ansible-lint` ne chargent le plugin de sortie
> configuré dans `ansible.cfg` : une erreur de ce côté ne se voit qu'à la
> première exécution réelle. C'est pour ça que le §5 lance le playbook
> pour de bon.

---

## 3. La connexion — 2 min

```bash
cd infra/ansible
export G4_SSH_HOST=<VM_IP>
export G4_SSH_USER=<user>
export G4_SSH_KEY=~/.ssh/g4_test

ansible -m ping all
```

Attendu : `g4-host | SUCCESS => {"ping": "pong"}`.

**Ces variables ne valent que pour le terminal courant.** Un nouvel
onglet, ou un `sudo`, les perd — c'est la cause la plus fréquente
d'échec au §5. Contrôle rapide :

```bash
echo "host=[$G4_SSH_HOST] user=[$G4_SSH_USER] key=[$G4_SSH_KEY]"
```

Si le message est `G4_SSH_HOST is empty or unset`, c'est exactement ce
que dit l'erreur : la variable n'est pas exportée ici. L'inventaire n'a
volontairement aucune valeur par défaut, pour que ce cas se signale
lui-même plutôt que d'échouer sur une résolution DNS incompréhensible.

---

## 4. Les identifiants de sauvegarde — 2 min

Le playbook commence par un `assert` : sans ces variables, il s'arrête
avant d'écrire quoi que ce soit.

```bash
export RESTIC_REPOSITORY='azure:g4-backups:/restic-prod'
export RESTIC_PASSWORD='une-passphrase'
export AZURE_ACCOUNT_NAME=... AZURE_ACCOUNT_KEY=...
export POSTGRES_USER=g4_app POSTGRES_PASSWORD=... POSTGRES_DB=g4_db
```

Pour un test sans Azure, un dépôt local suffit — le playbook ne vérifie
que la cohérence du schéma :

```bash
export RESTIC_REPOSITORY=/srv/restic-test
```

---

## 5. Premier passage — 5 min

**Pour de vrai, pas en `--check`.** Sur une machine où rien n'est encore
installé, le mode simulation ne peut rien évaluer : il produit une
cascade de faux signaux. Il prend son sens au second passage (§7).

```bash
ansible-playbook site.yml -K
```

`-K` demande le mot de passe sudo une fois. Attendu : une dizaine de
tâches, toutes en `ok` ou `changed`, aucune en `failed`.

---

## 6. Vérifier ce qui a réellement atterri — 5 min

C'est la section qui distingue un test d'un simple « le playbook est
vert ».

```bash
ssh -i $G4_SSH_KEY $G4_SSH_USER@$G4_SSH_HOST 'bash -s' <<'EOS'
echo "--- paquets ---"
command -v pg_dump && pg_dump --version
command -v bunzip2 >/dev/null && echo "bunzip2 présent"

echo "--- restic ---"
which restic
restic version

echo "--- script et configuration ---"
ls -l /opt/g4/bin/db-backup-to-azure.sh
sudo ls -l /etc/g4/backup.env
EOS
```

Trois points à contrôler dans cette sortie :

- **`which restic` doit répondre `/usr/local/bin/restic`**, pas
  `/usr/bin/restic`. Le playbook installe la release officielle
  précisément parce que le paquet de la distribution est parfois compilé
  sans les backends cloud.
- **`/opt/g4/bin/db-backup-to-azure.sh` en `0755`**, appartenant à
  l'utilisateur de déploiement.
- **`/etc/g4/backup.env` en `-rw------- root root`**. Il contient la
  passphrase du dépôt : tout autre mode est une fuite.

### Le backend restic répond-il vraiment ?

C'est le contrôle que le playbook fait déjà, et qu'il vaut la peine de
refaire à la main pour comprendre ce qu'il vérifie :

```bash
ssh -i $G4_SSH_KEY $G4_SSH_USER@$G4_SSH_HOST \
  "/usr/local/bin/restic -r 'azure:probe:/probe' cat config"
```

- `invalid backend` → ce binaire ne gère pas Azure. Le playbook aurait dû
  échouer ; s'il est passé, la tâche de vérification a un problème.
- Une erreur d'authentification ou de container introuvable → **c'est le
  bon résultat**. Le schéma est reconnu, seule la connexion échoue faute
  d'identifiants valides.

L'analyse du schéma se fait avant toute connexion : c'est ce qui rend ce
contrôle instantané et utilisable sans identifiants.

---

## 7. L'idempotence — 3 min

C'est la propriété qu'un jury demande, et la seule utilisation de
`--check` qui apporte quelque chose.

```bash
ansible-playbook site.yml -K --check --diff
```

Attendu dans le `PLAY RECAP` : `changed=0`.

Une tâche qui reste en `changed` à chaque passage est un bug — elle
signifie que le playbook réécrit quelque chose sans raison. Les
suspectes habituelles sont les `command` sans `creates:` et les `copy`
dont le contenu varie.

> Le `--check` sur `/etc/g4/backup.env` affiche `changed` si le contenu
> diffère, mais `no_log: true` masque le diff : c'est voulu, ce fichier
> contient la passphrase.

---

## 8. Une vraie sauvegarde — 5 min

Le playbook a installé de quoi sauvegarder ; reste à le prouver. Il n'y a
pas de playbook dédié — une commande suffit :

```bash
ssh -i $G4_SSH_KEY $G4_SSH_USER@$G4_SSH_HOST \
  'set -a; . /etc/g4/backup.env; set +a; sudo -E /opt/g4/bin/db-backup-to-azure.sh all'
```

Sans base PostgreSQL sur la VM, l'étape `dump` échouera — c'est attendu,
et ça valide déjà la moitié du chemin : le script est là, il lit ses
variables, et il s'arrête avec un message clair.

Pour aller au bout, lancez une base jetable sur la VM :

```bash
docker run -d --name g4-db-test -p 5432:5432 \
  -e POSTGRES_USER=g4_app -e POSTGRES_PASSWORD=test -e POSTGRES_DB=g4_db \
  timescale/timescaledb:2.17.2-pg16
```

puis relancez la commande. Attendu en fin de sortie : `snapshots
present:` suivi d'un instantané.

---

## 9. La portabilité — 3 min

L'argument défendu dans le README : aucune valeur du dépôt n'est propre à
une machine. Vérifiez-le plutôt que de le croire.

```bash
G4_SSH_HOST=<autre-machine> ansible-playbook site.yml -K
```

Aucun fichier modifié, aucun inventaire ajouté. Si vous n'avez pas de
seconde VM, la démonstration marche aussi contre `localhost` :

```bash
G4_SSH_HOST=127.0.0.1 G4_SSH_USER=$USER ansible-playbook site.yml -K
```

---

## 10. Repartir de zéro

```bash
ssh -i $G4_SSH_KEY $G4_SSH_USER@$G4_SSH_HOST 'bash -s' <<'EOS'
sudo rm -rf /opt/g4 /etc/g4 /usr/local/bin/restic /usr/local/src/restic-*
sudo apt-get remove -y --purge postgresql-client
EOS
```

Ou restaurez l'instantané de la §1 — plus rapide, et ça vérifie que le
provisionnement repart bien d'une machine nue.

---

## 11. Dépannage

| Symptôme | Cause |
|---|---|
| `G4_SSH_HOST is empty or unset` | la variable n'est pas exportée dans **ce** terminal — §3 |
| `Timeout waiting for privilege escalation prompt` | la cible utilise **sudo-rs** — §1. Rien à voir avec le playbook |
| `sudo: interactive authentication is required` | `-K` oublié, ou le compte n'est pas dans le groupe `sudo` |
| `Missing sudo password` | idem : ajouter `-K` |
| L'`assert` échoue au démarrage | un `RESTIC_*` ou `POSTGRES_*` n'est pas exporté — §4 |
| La tâche `Verify that this restic supports...` échoue | le binaire installé n'a pas le backend visé. Vérifier que `which restic` répond `/usr/local/bin/restic` |
| `changed` non nul au second passage | une tâche n'est pas idempotente — §7 |
| `The 'community.general.yaml' callback plugin has been removed` | `ansible.cfg` a été modifié : la clé est `callback_result_format`, pas `stdout_callback = yaml` |

---

## 12. Ce qui change sur le serveur de l'école

| | VM de test | Serveur de l'école |
|---|---|---|
| Variables `G4_SSH_*` | exportées à la main | idem — le provisionnement reste manuel et rare |
| `RESTIC_*` / `AZURE_*` | valeurs de test, ou dépôt local | vraies valeurs, issues des sorties Terraform |
| Base de données | conteneur jetable | la vraie, déployée par `deploy.yml` |
| `sudo` | à vous de voir | à vérifier avant le jour J — §1 |
| Instantané avant essai | oui | impossible : d'où l'intérêt de tout avoir répété ici |

Le reste — playbook, inventaire, variables, script — est **strictement
identique**. C'est l'intérêt de n'avoir aucune valeur propre à une
machine dans le dépôt.

## Voir aussi

- `infra/ansible/README.md` — ce que le playbook installe, et pourquoi
- `docs/cicd/backup-restore.md` — la procédure de restauration (branche
  `feature/db-backup-restore`)
