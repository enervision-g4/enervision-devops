# infra/ansible

Prépare un hôte à sauvegarder la base : `postgresql-client`, `restic`, le
script de sauvegarde et son fichier d'identifiants.

```
ansible.cfg
inventory.ini        la machine cible, via variables d'environnement
group_vars/all.yml   chemins, versions, secrets lus dans l'environnement
site.yml             le playbook — tâches inline, pas de rôle
backup.env.j2        le gabarit de /etc/g4/backup.env
```

## Lancer

```bash
pip install ansible-core
cd infra/ansible

export G4_SSH_HOST=<adresse> G4_SSH_USER=<user> G4_SSH_KEY=~/.ssh/g4_deploy
export RESTIC_REPOSITORY=... RESTIC_PASSWORD=... \
       AZURE_ACCOUNT_NAME=... AZURE_ACCOUNT_KEY=... \
       POSTGRES_USER=... POSTGRES_PASSWORD=... POSTGRES_DB=...

ansible -m ping all          # vérifier la connexion avant tout

ansible-playbook site.yml -K

# Second passage : tout doit être "ok", rien en "changed".
ansible-playbook site.yml -K --check --diff
```

> **Ne pas lancer `--check` en premier sur une machine neuve.** Le mode
> simulation ne peut rien évaluer d'un hôte où les paquets ne sont pas
> installés : on obtient une cascade de faux signaux. `--check` prend son
> sens au **second** passage, pour prouver l'idempotence.

## Élévation de privilèges

Le playbook porte `become: true` — installer des paquets demande root —
et se lance avec `-K`, qui demande le mot de passe sudo une seule fois.
Le compte doit être membre du groupe `sudo`. Il n'a **pas** besoin de
`NOPASSWD`, et c'est délibéré : le provisionnement est rare et lancé par
une personne, alors que le déploiement applicatif tourne à chaque poussée
sans aucune élévation. Donner `NOPASSWD` échangerait cette propriété
contre rien.

> Sur les Ubuntu récentes, `sudo` peut être **sudo-rs**, qui ne pilote
> pas l'invite de mot de passe comme GNU sudo. Ansible attend alors une
> invite qui ne vient jamais et sort sur
> `Timeout waiting for privilege escalation prompt`. Vérifier avec
> `sudo --version` ; installer GNU sudo si c'est le cas.

## Portabilité

Aucune valeur du dépôt n'est propre à une machine : l'adresse,
l'utilisateur et la clé viennent de variables d'environnement. Viser une
autre machine — une VM de reprise, une VM de test — c'est exporter un
autre `G4_SSH_HOST`, pas éditer un fichier.

```bash
G4_SSH_HOST=<autre-machine> ansible-playbook site.yml -K
```

## Secrets

Pas d'ansible-vault, pas de fichier chiffré dans le dépôt. Tout arrive en
variable d'environnement : depuis les secrets de l'Environment GitHub en
CI, par `export` à la main sinon. Le playbook commence par un `assert` —
l'échec est immédiat et explicite plutôt que tardif et obscur.

| Variable | Rôle |
|---|---|
| `G4_SSH_HOST` | **obligatoire** — adresse de la machine. Aucune valeur par défaut : le playbook s'arrête en le disant si elle manque. |
| `G4_SSH_USER` `G4_SSH_PORT` `G4_SSH_KEY` | connexion (défauts : `enervision-g4`, `22`, clé de l'agent) |
| `RESTIC_*` `AZURE_*` `POSTGRES_*` | contenu de `/etc/g4/backup.env` |

## Sauvegarder à la main

Pas de playbook dédié pour ça — une commande suffit :

```bash
ssh <hote> 'set -a; . /etc/g4/backup.env; set +a; /opt/g4/bin/db-backup-to-azure.sh all'
```

Utile avant une opération risquée : le workflow planifié tourne une fois
par nuit, celle-ci prend un instantané tout de suite.

## Ce que ce dossier ne fait pas

- **Déployer l'application** — c'est `.github/workflows/deploy.yml`.
- **Monter les runners self-hosted** — `infra/runners/`, à la main.
- **Durcir l'hôte** — le serveur de l'école est partagé avec d'autres
  groupes ; sa politique réseau et SSH ne relève pas d'un projet parmi
  d'autres.
- **Installer les clés SSH autorisées** — Ansible a besoin que la
  connexion fonctionne déjà. Poser la clé (`ssh-copy-id`) est un
  prérequis manuel.
- **Restaurer** — la procédure est manuelle et documentée dans
  `docs/cicd/backup-restore.md`.

## Dépendance

Le playbook installe `scripts/db-backup-to-azure.sh`. Ce fichier arrive
avec la branche `feature/db-backup-restore`, qui doit donc être fusionnée
**avant** celle-ci.

## Vérifier

```bash
ansible-lint --profile production .
ansible-playbook site.yml --syntax-check
```

> `--syntax-check` et `ansible-lint` ne chargent pas le plugin de sortie
> configuré dans `ansible.cfg` : une erreur de ce côté ne se voit qu'à la
> première exécution réelle.
