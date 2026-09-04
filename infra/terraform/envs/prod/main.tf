# Environnement prod — namespace g4-prod du cluster k3s.
#
# Ne contient que le stockage des sauvegardes de production.
#
# La protection de branche GitHub se règle à la main dans Settings (liste
# exacte des cases dans docs/cicd/runbook.md) : c'est six cases cochées
# une fois pour toutes. La décrire en Terraform demandait un fournisseur
# supplémentaire et un jeton GitHub, pour une configuration qui ne bouge
# jamais.

locals {
  tags = {
    project     = "enervision-g4"
    environment = "prod"
    purpose     = "database-backup"
    managed_by  = "terraform"
  }
}

module "backup_storage" {
  source = "../../modules/azure-backup-storage"

  resource_group_name  = "g4-backup-prod"
  location             = var.location
  storage_account_name = var.storage_account_name
  container_name       = "g4-backups"

  # prod : ZRS répartit les copies sur trois zones de la même région —
  # la donnée survit à la perte d'un datacentre sans quitter la France,
  # ce qui préserve l'argument de souveraineté (GRS répliquerait vers une
  # région secondaire, potentiellement hors du périmètre voulu).
  replication_type     = "ZRS"
  cool_tier_after_days = 30
  soft_delete_days     = 30

  writer_principal_ids = var.backup_writer_principal_ids
  reader_principal_ids = var.backup_reader_principal_ids

  tags = local.tags
}
