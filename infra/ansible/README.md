# infra/ansible

Provisionnement des machines : d'un serveur nu à un cluster k3s prêt à
recevoir des déploiements. Ansible ne fait **pas** les déploiements —
ceux-ci passent par `scripts/k8s-apply.sh` en SSH, appelé par
`.github/workflows/deploy-k8s.yml`.

```
inventories/
  onprem.ini            le serveur de l'école
  azure.ini             une VM Azure, ou tout autre hôte Linux
  group_vars/all.yml    réglages communs, secrets lus dans l'environnement
roles/
  k3s_server            k3s, kubectl, kustomize, namespaces, kubeconfig
  db_backup_agent       restic, client PostgreSQL, scripts de reprise
playbooks/
  site.yml              provisionnement complet
  bootstrap-cluster.yml k3s seul — à lancer en premier
  backup.yml            sauvegarde à la demande
```

## Portabilité

Les rôles ne référencent aucune adresse ni aucun nom propre au serveur de
l'école. Changer de machine cible, c'est changer d'inventaire :

```bash
ansible-playbook -i inventories/onprem.ini playbooks/site.yml
ansible-playbook -i inventories/azure.ini  playbooks/site.yml
```

`azure.ini` n'est pas décoratif : c'est le chemin de reprise si le
serveur on-premise devenait indisponible durablement
(`docs/cicd/infra-decision.md`).

## Secrets

Pas d'ansible-vault, pas de fichier chiffré dans le dépôt. Tout arrive en
variable d'environnement : depuis les secrets de l'Environment GitHub en
CI, par `export` à la main. Une valeur absente vaut `""`, et les tâches
qui en dépendent commencent par un `assert` — l'échec est immédiat et
explicite plutôt que tardif et obscur.

| Variable | Utilisée par |
|---|---|
| `G4_SSH_HOST` `G4_SSH_USER` `G4_SSH_PORT` `G4_SSH_KEY` | connexion |
| `DEPLOY_PUBKEY` | clé publique autorisée sur le serveur |
| `RESTIC_*` `AZURE_*` `POSTGRES_*` | outillage de sauvegarde |

## Lancer

```bash
pip install ansible-core
ansible-galaxy collection install -r requirements.yml

# Voir ce qui changerait, sans rien changer :
ansible-playbook -i inventories/onprem.ini playbooks/site.yml --check --diff

# Premier passage sur un serveur neuf : le cluster d'abord.
ansible-playbook -i inventories/onprem.ini playbooks/bootstrap-cluster.yml
```

`bootstrap-cluster.yml` est volontairement séparé de `site.yml` : monter
le cluster ne doit pas pouvoir modifier, du même coup, la configuration
SSH de la machine.

## Vérifier

```bash
ansible-lint --profile production .
for p in playbooks/*.yml; do
  ansible-playbook -i inventories/onprem.ini "$p" --syntax-check
done
```

## Ce que ce dossier ne fait pas

Les **runners GitHub self-hosted** ne sont pas provisionnés ici. Ils
tournent depuis `infra/runners/docker-compose.runners.yml`, monté une
fois à la main.

Les **déploiements** non plus : ils passent par `scripts/k8s-apply.sh`,
appelé en SSH par `.github/workflows/deploy-k8s.yml`. Ansible provisionne
la machine, Kubernetes fait tourner les applications.

## Note de nommage

Les répertoires de rôles utilisent des underscores (`k3s_server` et non
`k3s-server`) : `ansible-lint` en profil `production` impose le motif
`^[a-z][a-z0-9_]*$`. Les variables de rôle sont préfixées par le nom du
rôle pour la même raison.
