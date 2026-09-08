# Bootstrap, to be run ONCE before anything else.
#
# Creates the storage account that will hold the remote state of the main
# module (../main.tf). This is the only Terraform in the repository whose
# state stays local: it cannot store itself in a resource it has not
# created yet.
#
#   cd infra/terraform/bootstrap
#   cp terraform.tfvars.example terraform.tfvars   # then adjust
#   terraform init && terraform apply
#   terraform output -raw backend_config > ../backend.hcl
#
# Keep the terraform.tfstate produced here outside the repository.
# Versioning and soft delete are enabled: a state file overwritten by
# mistake stays recoverable for 30 days.

terraform {
  required_version = ">= 1.16"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.4"
    }
  }
}

provider "azurerm" {
  features {}
}

variable "storage_account_name" {
  description = "Storage account holding the Terraform state. 3-24 characters, lowercase letters and digits, globally unique across Azure."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.storage_account_name))
    error_message = "3 to 24 lowercase letters or digits only."
  }
}

variable "location" {
  description = "Azure region for the Terraform state."
  type        = string
  default     = "francecentral"
}

locals {
  resource_group_name = "g4-tfstate"
  container_name      = "tfstate"

  tags = {
    project    = "enervision-g4"
    purpose    = "terraform-state"
    managed_by = "terraform"
  }
}

resource "azurerm_resource_group" "tfstate" {
  name     = local.resource_group_name
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
  name                  = local.container_name
  storage_account_id    = azurerm_storage_account.tfstate.id
  container_access_type = "private"
}

output "backend_config" {
  description = "Contents to write into ../backend.hcl."
  value       = <<-EOT
    resource_group_name  = "${azurerm_resource_group.tfstate.name}"
    storage_account_name = "${azurerm_storage_account.tfstate.name}"
    container_name       = "${azurerm_storage_container.tfstate.name}"
    key                  = "prod/terraform.tfstate"
  EOT
}
