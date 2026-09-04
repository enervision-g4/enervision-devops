output "storage_account_name" {
  description = "AZURE_ACCOUNT_NAME du secret ENV_FILE_CONTENTS de l'Environment onprem-prod."
  value       = module.backup_storage.storage_account_name
}

output "storage_account_key" {
  description = "AZURE_ACCOUNT_KEY du même secret."
  value       = module.backup_storage.storage_account_key
  sensitive   = true
}

output "restic_repository" {
  description = "RESTIC_REPOSITORY à utiliser en production."
  value       = "${module.backup_storage.restic_repository}-prod"
}
