output "backend_config" {
  description = "Contenu à écrire dans envs/<stage>/backend.hcl (ajuster la clé selon le stage)."
  value       = <<-EOT
    resource_group_name  = "${azurerm_resource_group.tfstate.name}"
    storage_account_name = "${azurerm_storage_account.tfstate.name}"
    container_name       = "${azurerm_storage_container.tfstate.name}"
    key                  = "prod/terraform.tfstate"
  EOT
}

output "tfstate_resource_group" {
  description = "Variable GitHub TFSTATE_RESOURCE_GROUP."
  value       = azurerm_resource_group.tfstate.name
}

output "tfstate_storage_account" {
  description = "Variable GitHub TFSTATE_STORAGE_ACCOUNT."
  value       = azurerm_storage_account.tfstate.name
}

output "tfstate_container" {
  description = "Variable GitHub TFSTATE_CONTAINER."
  value       = azurerm_storage_container.tfstate.name
}
