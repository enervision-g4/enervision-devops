# Zone d'atterrissage Azure des sauvegardes chiffrées.
#
# C'est le SEUL usage d'Azure dans l'architecture : aucune charge
# applicative n'y tourne. Le périmètre est volontairement étroit, et
# réservé pour accueillir plus tard la zone externe déjà prévue
# (archive long terme + module ML).
#
# Ce que ce module ne fait volontairement PAS : supprimer des blobs selon
# leur âge. Un dépôt restic est dédupliqué — un blob ancien peut contenir
# des morceaux encore référencés par le snapshot d'hier. Une règle de
# cycle de vie qui supprime par âge corrompt le dépôt. La rétention
# (30 quotidiennes, 12 mensuelles) est appliquée par `restic forget
# --prune` dans scripts/db-backup-to-azure.sh. La règle ci-dessous ne fait
# que du changement de tier, qui est réversible et sans effet sur les
# données.

resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_storage_account" "this" {
  name                     = var.storage_account_name
  resource_group_name      = azurerm_resource_group.this.name
  location                 = azurerm_resource_group.this.location
  account_tier             = "Standard"
  account_replication_type = var.replication_type
  account_kind             = "StorageV2"
  access_tier              = "Hot"

  # Posture de sécurité (auditée dans docs/cicd/infra-decision.md) :
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false

  # restic s'authentifie aujourd'hui par clé de compte partagée
  # (AZURE_ACCOUNT_KEY) : la désactiver couperait les sauvegardes.
  # La clé est le seul identifiant à large portée du dispositif — sa
  # rotation est décrite dans docs/cicd/runbook.md.
  shared_access_key_enabled = true

  # Les sauvegardes sont poussées depuis le serveur on-premise, via
  # Internet : le compte doit rester joignable publiquement. La protection
  # ne vient donc pas du réseau mais du chiffrement restic côté client
  # (les blobs sont illisibles sans RESTIC_PASSWORD, y compris pour
  # Microsoft) et du container privé.
  public_network_access_enabled = true

  blob_properties {
    versioning_enabled = true

    delete_retention_policy {
      days = var.soft_delete_days
    }

    container_delete_retention_policy {
      days = var.soft_delete_days
    }
  }

  tags = var.tags
}

resource "azurerm_storage_container" "this" {
  name                  = var.container_name
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = "private"
}

resource "azurerm_storage_management_policy" "this" {
  count              = var.cool_tier_after_days > 0 ? 1 : 0
  storage_account_id = azurerm_storage_account.this.id

  rule {
    name    = "cool-old-backup-blobs"
    enabled = true

    filters {
      prefix_match = ["${var.container_name}/"]
      blob_types   = ["blockBlob"]
    }

    actions {
      base_blob {
        tier_to_cool_after_days_since_modification_greater_than = var.cool_tier_after_days
      }
      # Les *versions* (soft-delete) peuvent être purgées par âge sans
      # risque : ce ne sont pas les blobs vivants du dépôt restic.
      version {
        delete_after_days_since_creation = var.soft_delete_days
      }
    }
  }
}

# Moindre privilège : la portée de ces attributions est l'identifiant du
# compte de stockage, pas l'abonnement ni le groupe de ressources. Une
# identité listée ici ne peut rien voir d'autre dans Azure.
resource "azurerm_role_assignment" "writers" {
  for_each             = toset(var.writer_principal_ids)
  scope                = azurerm_storage_account.this.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = each.value
}

resource "azurerm_role_assignment" "readers" {
  for_each             = toset(var.reader_principal_ids)
  scope                = azurerm_storage_account.this.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = each.value
}
