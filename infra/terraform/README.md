# infra/terraform

Le seul Azure du projet : le stockage des sauvegardes chiffrées.

```
modules/
  azure-backup-storage/   groupe de ressources, compte de stockage,
                          container privé, politique de cycle de vie,
                          attributions de rôle à portée limitée
envs/
  prod/                   stockage de prod + gouvernance du dépôt
bootstrap/                compte de stockage de l'état distant (état LOCAL)
```

## Ordre d'exécution

`bootstrap/` d'abord — il crée le stockage où les autres rangeront leur
état. C'est le seul module dont l'état reste local, par nécessité : il ne
peut pas se stocker dans une ressource qu'il n'a pas encore créée.

```bash
cd bootstrap
cp terraform.tfvars.example terraform.tfvars
terraform init && terraform apply
terraform output -raw backend_config > ../envs/prod/backend.hcl

cd ../envs/prod
cp terraform.tfvars.example terraform.tfvars
terraform init -backend-config=backend.hcl
terraform plan && terraform apply
```

## Vérifier sans identifiants Azure

```bash
terraform fmt -check -recursive
cd envs/prod && terraform init -backend=false && terraform validate
```

## Trois décisions à connaître

**La rétention n'est pas gérée par Azure.** La politique de cycle de vie
ne fait que du changement de tier. Supprimer des blobs par âge dans un
dépôt restic — qui est dédupliqué — détruirait des blocs encore
référencés par des instantanés récents et corromprait tout le dépôt. La
rétention (30 quotidiennes, 12 mensuelles) est appliquée par
`restic forget --prune`, dans `scripts/db-backup-to-azure.sh`.

**Les attributions de rôle ont pour portée le compte de stockage**, pas
l'abonnement ni le groupe de ressources. Une identité listée dans
`writer_principal_ids` ou `reader_principal_ids` ne voit rien d'autre
dans Azure. C'est le moindre privilège appliqué, pas seulement invoqué.

**Il n'y a qu'un seul environnement.** Sauvegarder des données de
développement, jetables par définition, coûterait un compte de stockage
et une rétention pour rien — le CronJob du namespace `g4-dev` est donc
livré suspendu. Le répertoire `envs/` est conservé pour que l'ajout d'un
second environnement reste une copie de dossier et non une
restructuration.

**La protection de branche GitHub n'est pas gérée ici.** Six cases à
cocher une fois pour toutes dans Settings ne justifiaient pas un
fournisseur Terraform supplémentaire et un jeton GitHub à faire tourner.
La liste exacte est dans `docs/cicd/runbook.md`, section 1.4.

Voir `docs/cicd/infra-decision.md` et `docs/cicd/runbook.md`.
