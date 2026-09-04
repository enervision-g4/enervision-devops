variable "location" {
  description = "Région Azure de l'état Terraform."
  type        = string
  default     = "francecentral"
}

variable "resource_group_name" {
  description = "Groupe de ressources dédié à l'état Terraform."
  type        = string
  default     = "g4-tfstate"
}

variable "storage_account_name" {
  description = "Compte de stockage de l'état. 3-24 caractères, minuscules et chiffres, unique dans tout Azure."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.storage_account_name))
    error_message = "storage_account_name : 3 à 24 caractères, minuscules ou chiffres uniquement."
  }
}

variable "container_name" {
  description = "Container Blob qui contient les fichiers d'état."
  type        = string
  default     = "tfstate"
}
