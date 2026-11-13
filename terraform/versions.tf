terraform {
  required_version = ">= 1.9"

  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 4.6"
    }
  }
  # Local state (gitignored): this only manages containers on your own Docker host.
}

provider "docker" {
  host = var.docker_host
}

# A second Docker host: add an aliased provider and a second module block for the
# boxes that live there, e.g.
#
#   provider "docker" {
#     alias = "mini"
#     host  = "ssh://me@mini"
#   }
#
#   module "box_mini" {
#     source    = "./modules/box"
#     for_each  = var.mini_boxes
#     providers = { docker = docker.mini }
#     ...same arguments as module.box...
#   }
