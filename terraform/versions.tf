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
