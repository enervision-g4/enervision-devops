variable "location" {
  description = "Région Azure."
  type        = string
  default     = "francecentral"
}

variable "storage_account_name" {
  description = "Compte de stockage des sauvegardes de production. Unique dans tout Azure."
  type        = string
}

variable "backup_writer_principal_ids" {
  description = "Object IDs autorisés à écrire les sauvegardes (portée : le seul compte de stockage)."
  type        = list(string)
  default     = []
}

variable "backup_reader_principal_ids" {
  description = "Object IDs autorisés à lire les sauvegardes, pour restaurer (portée : le seul compte de stockage)."
  type        = list(string)
  default     = []
}
