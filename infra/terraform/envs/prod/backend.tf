# État distant dans Azure Blob (compte créé une fois par ../../bootstrap).
#
# Configuration *partielle* volontairement : le nom du compte de stockage
# n'est pas une donnée à commiter, et les valeurs diffèrent d'un
# environnement à l'autre. Elles sont fournies au moment de l'init :
#
#   terraform init -backend-config=backend.hcl
#
# ou, en CI, par -backend-config="clé=valeur" (cf
# .github/workflows/terraform.yml). La clé d'état de cet environnement
# est "prod/terraform.tfstate" : dev et prod ne partagent jamais un état.
terraform {
  backend "azurerm" {}
}
