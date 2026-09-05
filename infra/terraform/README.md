# infra/terraform

Le seul Azure du projet : le stockage des sauvegardes chiffrées de la
base. Aucune charge applicative n'y tourne, le raisonnement complet est
dans `docs/cicd/infra-decision.md`.

```
main.tf                    tout : backend, provider, variables, ressources, sorties
terraform.tfvars.example   les 3 valeurs à renseigner
backend.hcl.example        où vit l'état distant
bootstrap/main.tf          le compte de stockage de l'état (état LOCAL, une seule fois)
```

## Ordre d'exécution

`bootstrap/` d'abord : il crée le stockage où le module principal rangera
son état. C'est le seul dont l'état reste local, par nécessité, il ne
peut pas se stocker dans une ressource qu'il n'a pas encore créée.

```bash
cd bootstrap
cp terraform.tfvars.example terraform.tfvars   # choisir un nom unique
terraform init && terraform apply
terraform output -raw backend_config > ../backend.hcl

cd ..
cp terraform.tfvars.example terraform.tfvars
terraform init -backend-config=backend.hcl
terraform plan && terraform apply
```

Puis relever les sorties, qui alimentent les secrets de l'Environment
GitHub `onprem-prod` :

```bash
terraform output storage_account_name    # AZURE_ACCOUNT_NAME
terraform output -raw storage_account_key # AZURE_ACCOUNT_KEY (sensible)
terraform output restic_repository        # RESTIC_REPOSITORY
```

## En intégration continue

`.github/workflows/terraform.yml` se déclenche dès qu'un fichier de
`infra/terraform/` change :

| Job | Fait quoi | Identifiants Azure |
|---|---|---|
| `validate` | `fmt -check -recursive`, puis `init -backend=false` + `validate` sur les deux modules racines | **aucun** |
| `plan` | `terraform plan` sur les pull requests, résumé dans l'onglet Checks | requis, se saute proprement s'ils sont absents |

Le job `validate` tourne sans rien configurer : `-backend=false` ignore
l'état distant et ne résout que le fournisseur. Le job `plan` vérifie
d'abord la présence de `ARM_CLIENT_ID` et s'annonce comme sauté plutôt
que d'échouer, pour que le workflow reste vert tant que l'abonnement
Azure n'existe pas.

Il n'y a délibérément **pas** d'étape `apply` : créer le stockage est une
opération ponctuelle, faite par une personne qui recopie ensuite les
sorties dans les secrets de l'Environment GitHub.

L'analyse de sécurité statique (checkov) est ailleurs, dans
`security-scan.yml`, pilotée par son entrée `scan-terraform`. Elle est
informative : beaucoup de ses règles portent sur des défauts Azure de
faible gravité qui sont ici des choix assumés.

## Vérifier sans identifiants Azure

```bash
terraform fmt -check -recursive
terraform init -backend=false && terraform validate
```

## Trois décisions à connaître

**La rétention n'est pas gérée par Azure.** La politique de cycle de vie
ne fait que du changement de tier. Supprimer des blobs par âge dans un
dépôt restic, qui est dédupliqué, détruirait des morceaux encore
référencés par des instantanés récents et corromprait tout le dépôt. La
rétention réelle (30 quotidiennes, 12 mensuelles) est appliquée par
`restic forget --prune`.

**Les attributions de rôle ont pour portée le compte de stockage**, pas
l'abonnement ni le groupe de ressources. Une identité listée dans
`backup_writer_principal_ids` ou `backup_reader_principal_ids` ne voit
rien d'autre dans Azure. C'est le moindre privilège appliqué, pas
seulement invoqué. Les deux listes sont vides tant que restic utilise la
clé de compte partagée.

**ZRS et non GRS en production.** ZRS répartit les copies sur trois zones
de la même région : la donnée survit à la perte d'un datacentre sans
quitter la France. GRS répliquerait vers une région secondaire,
potentiellement hors du périmètre voulu, ce qui casserait l'argument de
souveraineté.
