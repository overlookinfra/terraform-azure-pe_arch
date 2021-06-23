# Terraform setup stuff, required providers, where they are sourced from, and
# the provider's configuration requirements.
terraform {
  required_providers {
    hiera5 = {
      source  = "sbitio/hiera5"
      version = "0.2.7"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "2.64.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.1.0"
    }
  }
}

# Sets the variables that'll be interpolated to determine where variables are
# located in the hierarchy
provider "hiera5" {
  scope = {
    architecture = var.architecture
    replica      = var.replica
  }
}

# GCP region and project to operating within
provider "azurerm" {
  features {}
}

# hiera lookps
data "hiera5" "server_count" {
  key = "server_count"
}
data "hiera5" "database_count" {
  key = "database_count"
}
data "hiera5_bool" "has_compilers" {
  key = "has_compilers"
}

# It is intended that multiple deployments can be launched easily without
# name collisions
resource "random_id" "deployment" {
  byte_length = 3
}

# Resource group is so central it makes sense to live in the main tf outside of modules
resource "azurerm_resource_group" "resource_group" {
  name     = var.project
  location = var.region
  tags     = {
   name    = "pe-${var.project}-${local.id}"
 }
}

# Collect some repeated values used by each major component module into one to
# make them easier to update
locals {
  compiler_count = data.hiera5_bool.has_compilers.value ? var.compiler_count : 0
  id             = random_id.deployment.hex
  has_lb         = data.hiera5_bool.has_compilers.value ? true : false
}

# Contain all the networking configuration in a module for readability
module "networking" {
  source        = "./modules/networking"
  id            = local.id
  resourcegroup = azurerm_resource_group.resource_group
  allow         = var.firewall_allow
  region        = var.region
}

# Contain all the loadbalancer configuration in a module for readability
module "loadbalancer" {
  source             = "./modules/loadbalancer"
  id                 = local.id
  ports              = ["8140", "8142"]
  region             = var.region
  instances          = module.instances.compilers
  has_lb             = local.has_lb
  resourcegroup      = azurerm_resource_group.resource_group
  virtual_network_id = module.networking.virtual_network_id
  compiler_nics      = module.instances.compiler_nics
  compiler_count     = local.compiler_count
  project            = var.project
}

# Contain all the instances configuration in a module for readability
module "instances" {
  source             = "./modules/instances"
  id                 = local.id
  virtual_network_id = module.networking.virtual_network_id
  subnet_id          = module.networking.subnet_id
  user               = var.user
  ssh_key            = var.ssh_key
  compiler_count     = local.compiler_count
  node_count         = var.node_count
  instance_image     = var.instance_image
  stack_name         = var.stack_name
  project            = var.project
  resource_group     = azurerm_resource_group.resource_group
  region             = var.region
  server_count       = data.hiera5.server_count.value
  database_count     = data.hiera5.database_count.value
}
