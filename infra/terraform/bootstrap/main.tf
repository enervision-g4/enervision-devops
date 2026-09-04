# Amorçage, à exécuter UNE SEULE FOIS avant tout le reste.
#
# Crée le compte de stockage qui hébergera l'état distant de envs/dev et
# envs/prod. C'est le seul Terraform du dépôt dont l'état reste local :
# il ne peut pas se stocker dans une ressource qu'il n'a pas encore
# créée. Le fichier terraform.tfstate produit ici est ignoré par Git — le
# perdre n'est pas dramatique (voir README du module), mais il vaut mieux
# le conserver hors du dépôt.
#
#   cd infra/terraform/bootstrap
#   cp terraform.tfvars.example terraform.tfvars   # puis adapter
#   terraform init && terraform apply
#   terraform output -raw backend_config > ../envs/prod/backend.hcl
#
# Le versioning et la suppression réversible sont activés : un état
# Terraform écrasé par erreur reste récupérable 30 jours.

locals {
  tags = {
    project    = "enervision-g4"
    purpose    = "terraform-state"
    managed_by = "terraform"
  }
}

resource "azurerm_resource_group" "tfstate" {
  name     = var.resource_group_name
  location = var.location
  tags     = local.tags
}

resource "azurerm_storage_account" "tfstate" {
  name                            = var.storage_account_name
  resource_group_name             = azurerm_resource_group.tfstate.name
  location                        = azurerm_resource_group.tfstate.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false

  blob_properties {
    versioning_enabled = true

    delete_retention_policy {
      days = 30
    }
  }

  tags = local.tags
}

resource "azurerm_storage_container" "tfstate" {
  name                  = var.container_name
  storage_account_id    = azurerm_storage_account.tfstate.id
  container_access_type = "private"
}
