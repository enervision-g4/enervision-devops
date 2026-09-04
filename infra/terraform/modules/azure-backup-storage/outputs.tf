output "resource_group_name" {
  description = "Groupe de ressources créé."
  value       = azurerm_resource_group.this.name
}

output "storage_account_name" {
  description = "AZURE_ACCOUNT_NAME à placer dans ENV_FILE_CONTENTS."
  value       = azurerm_storage_account.this.name
}

output "storage_account_id" {
  description = "Identifiant complet du compte — c'est la portée des attributions de rôle."
  value       = azurerm_storage_account.this.id
}

output "storage_account_key" {
  description = "AZURE_ACCOUNT_KEY à placer dans ENV_FILE_CONTENTS. Ne jamais l'afficher hors d'un poste de confiance."
  value       = azurerm_storage_account.this.primary_access_key
  sensitive   = true
}

output "restic_repository" {
  description = "Valeur exacte de RESTIC_REPOSITORY pour ce stage."
  value       = "azure:${azurerm_storage_container.this.name}:/restic"
}
