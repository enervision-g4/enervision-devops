variable "resource_group_name" {
  description = "Groupe de ressources contenant le stockage de sauvegarde."
  type        = string
}

variable "location" {
  description = "Région Azure. francecentral par défaut : les données restent sur le territoire national, ce qui est l'argument de souveraineté de docs/cicd/infra-decision.md."
  type        = string
  default     = "francecentral"
}

variable "storage_account_name" {
  description = "Compte de stockage des sauvegardes. 3-24 caractères, minuscules et chiffres, unique dans tout Azure."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.storage_account_name))
    error_message = "storage_account_name : 3 à 24 caractères, minuscules ou chiffres uniquement."
  }
}

variable "container_name" {
  description = "Container Blob privé visé par RESTIC_REPOSITORY."
  type        = string
  default     = "g4-backups"
}

variable "replication_type" {
  description = "Redondance du compte de stockage. LRS (3 copies dans un datacentre) suffit pour une sauvegarde hors-site d'un projet école ; GRS réplique dans une seconde région pour ~2x le prix."
  type        = string
  default     = "LRS"

  validation {
    condition     = contains(["LRS", "ZRS", "GRS", "GZRS"], var.replication_type)
    error_message = "replication_type doit valoir LRS, ZRS, GRS ou GZRS."
  }
}

variable "cool_tier_after_days" {
  description = "Bascule les blobs en tier Cool après N jours (optimisation de coût uniquement, aucune suppression). 0 désactive la règle."
  type        = number
  default     = 30
}

variable "soft_delete_days" {
  description = "Rétention de la suppression réversible (blobs, versions et containers). Filet de sécurité contre une suppression accidentelle ou malveillante."
  type        = number
  default     = 14
}

variable "reader_principal_ids" {
  description = "Object IDs autorisés à LIRE les sauvegardes (rôle Storage Blob Data Reader), portée limitée au seul compte de stockage. Typiquement l'identité qui restaure."
  type        = list(string)
  default     = []
}

variable "writer_principal_ids" {
  description = "Object IDs autorisés à lire ET écrire les sauvegardes (rôle Storage Blob Data Contributor), portée limitée au seul compte de stockage. Typiquement l'identité qui sauvegarde."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags appliqués à toutes les ressources du module."
  type        = map(string)
  default     = {}
}
