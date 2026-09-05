# Azure landing zone for the encrypted database backups — production.
terraform {
  required_version = ">= 1.16"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.4"
    }
  }

  # Remote state in Azure Blob (the account is created once by bootstrap/).
  #
  # Deliberately a *partial* configuration: the storage account name is
  # not something to commit. The values are supplied at init time:
  #
  #   terraform init -backend-config=backend.hcl
  backend "azurerm" {}
}

provider "azurerm" {
  features {
    resource_group {
      # Refuses to destroy a group that still contains resources this
      # state does not track. A guard rail on the backups.
      prevent_deletion_if_contains_resources = true
    }
  }
}

# ── Variables ─────────────────────────────────────────────────────────
# Only the ones that genuinely vary. Everything else is fixed below: a
# value that will never change does not need to be a variable.

variable "storage_account_name" {
  description = "Storage account holding the backups. 3-24 characters, lowercase letters and digits, globally unique across Azure."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.storage_account_name))
    error_message = "storage_account_name: 3 to 24 lowercase letters or digits only."
  }
}

variable "location" {
  description = "Azure region. francecentral keeps the data on national territory, which is the data-sovereignty argument made in docs/cicd/infra-decision.md."
  type        = string
  default     = "francecentral"
}

variable "backup_writer_principal_ids" {
  description = "Object IDs allowed to write backups (Storage Blob Data Contributor). Scope: this storage account only."
  type        = list(string)
  default     = []
}

variable "backup_reader_principal_ids" {
  description = "Object IDs allowed to read backups in order to restore (Storage Blob Data Reader). Scope: this storage account only."
  type        = list(string)
  default     = []
}

locals {
  resource_group_name = "g4-backup-prod"
  container_name      = "g4-backups"

  # ZRS spreads the copies across three zones of the same region: the
  # data survives losing one datacentre without leaving France. GRS would
  # replicate to a secondary region, possibly outside the intended
  # perimeter — which would break the sovereignty argument.
  replication_type = "ZRS"

  # Move blobs to the Cool tier after N days: old backups are almost
  # never read back. Purely a cost optimisation.
  cool_tier_after_days = 30

  # Soft delete: a safety net against accidental or malicious deletion.
  soft_delete_days = 30

  tags = {
    project     = "enervision-g4"
    environment = "prod"
    purpose     = "database-backup"
    managed_by  = "terraform"
  }
}

# ── Resources ─────────────────────────────────────────────────────────
#
# What this file deliberately does NOT do: delete blobs based on their
# age. A restic repository is deduplicated — an old blob may hold chunks
# still referenced by yesterday's snapshot. A lifecycle rule deleting by
# age corrupts the repository. Real retention (30 daily, 12 monthly) is
# applied by `restic forget --prune`, in scripts/db-backup-to-azure.sh.

resource "azurerm_resource_group" "backups" {
  name     = local.resource_group_name
  location = var.location
  tags     = local.tags
}

resource "azurerm_storage_account" "backups" {
  name                     = var.storage_account_name
  resource_group_name      = azurerm_resource_group.backups.name
  location                 = azurerm_resource_group.backups.location
  account_tier             = "Standard"
  account_replication_type = local.replication_type
  account_kind             = "StorageV2"
  access_tier              = "Hot"

  # Security posture (audited in docs/cicd/infra-decision.md):
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false

  # restic currently authenticates with the shared account key
  # (AZURE_ACCOUNT_KEY): disabling it would break the backups. That key
  # is the only broadly-scoped credential in the setup — rotating it is
  # documented in docs/cicd/backup-restore.md.
  shared_access_key_enabled = true

  # Backups are pushed from the on-premise server over the internet, so
  # the account must stay publicly reachable. Protection therefore does
  # not come from the network but from client-side restic encryption —
  # the blobs are unreadable without RESTIC_PASSWORD, Microsoft included
  # — and from the private container.
  public_network_access_enabled = true

  blob_properties {
    versioning_enabled = true

    delete_retention_policy {
      days = local.soft_delete_days
    }

    container_delete_retention_policy {
      days = local.soft_delete_days
    }
  }

  tags = local.tags
}

resource "azurerm_storage_container" "backups" {
  name                  = local.container_name
  storage_account_id    = azurerm_storage_account.backups.id
  container_access_type = "private"
}

resource "azurerm_storage_management_policy" "backups" {
  storage_account_id = azurerm_storage_account.backups.id

  rule {
    name    = "cool-old-backup-blobs"
    enabled = true

    filters {
      prefix_match = ["${local.container_name}/"]
      blob_types   = ["blockBlob"]
    }

    actions {
      base_blob {
        tier_to_cool_after_days_since_modification_greater_than = local.cool_tier_after_days
      }
      # Soft-deleted *versions* can safely be purged by age: they are not
      # the live blobs of the restic repository.
      version {
        delete_after_days_since_creation = local.soft_delete_days
      }
    }
  }
}

# Least privilege: these assignments are scoped to the STORAGE ACCOUNT
# id, not to the subscription nor to the resource group. An identity
# listed here can see nothing else in Azure.
resource "azurerm_role_assignment" "backup_writers" {
  for_each             = toset(var.backup_writer_principal_ids)
  scope                = azurerm_storage_account.backups.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = each.value
}

resource "azurerm_role_assignment" "backup_readers" {
  for_each             = toset(var.backup_reader_principal_ids)
  scope                = azurerm_storage_account.backups.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = each.value
}

# ── Outputs ───────────────────────────────────────────────────────────
# What to copy into the secrets of the onprem-prod GitHub Environment.

output "storage_account_name" {
  description = "AZURE_ACCOUNT_NAME."
  value       = azurerm_storage_account.backups.name
}

output "storage_account_key" {
  description = "AZURE_ACCOUNT_KEY. Never display it outside a trusted machine."
  value       = azurerm_storage_account.backups.primary_access_key
  sensitive   = true
}

output "restic_repository" {
  description = "RESTIC_REPOSITORY to use in production."
  value       = "azure:${azurerm_storage_container.backups.name}:/restic-prod"
}

output "storage_account_id" {
  description = "Full account id — this is the scope of the role assignments above."
  value       = azurerm_storage_account.backups.id
}
