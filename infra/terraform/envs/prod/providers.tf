provider "azurerm" {
  features {
    resource_group {
      # Refuse de détruire un groupe qui contient encore des ressources
      # non suivies par cet état. Garde-fou sur les sauvegardes.
      prevent_deletion_if_contains_resources = true
    }
  }
}
