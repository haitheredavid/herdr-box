locals {
  repo = abspath("${path.module}/..")
  # Rebuild the image (and replace the container) when anything baked into it changes.
  image_files = sort(setunion(
    fileset(local.repo, "bootstrap/**"),
    fileset(local.repo, "config/**"),
    fileset(local.repo, "image/**"),
  ))
  image_hash = sha1(join("", [for f in local.image_files : filesha1("${local.repo}/${f}")]))
  box_user   = regex("(?m)^BOX_USER=\"([^\"]+)\"", file("${local.repo}/config/box.conf"))[0]

  # Base image: the dotfiles checkout's linux/Dockerfile (working tree, uncommitted
  # changes included). Its .git and Finder litter don't trigger rebuilds.
  dotfiles = var.dotfiles_dir == "" ? null : abspath(pathexpand(var.dotfiles_dir))
  dotfiles_files = local.dotfiles == null ? [] : sort([
    for f in fileset(local.dotfiles, "**") : f
    if !startswith(f, ".git/") && !endswith(f, ".DS_Store")
  ])
  dotfiles_hash = sha1(join("", [for f in local.dotfiles_files : filesha1("${local.dotfiles}/${f}")]))
}

resource "docker_image" "dotfiles" {
  count = local.dotfiles == null ? 0 : 1
  name  = "${var.name}-dotfiles:latest"

  build {
    context    = local.dotfiles
    dockerfile = "linux/Dockerfile"
  }

  triggers = {
    dotfiles_hash = local.dotfiles_hash
  }
}

resource "docker_image" "box" {
  name = "${var.name}:latest"

  build {
    context    = local.repo
    dockerfile = "image/Dockerfile"
    build_args = {
      BASE = local.dotfiles == null ? "ubuntu:24.04" : docker_image.dotfiles[0].name
    }
  }

  triggers = {
    image_hash = local.image_hash
    base       = local.dotfiles == null ? "ubuntu:24.04" : docker_image.dotfiles[0].image_id
  }
}

# Persistent state; the container itself is disposable.
resource "docker_volume" "home" {
  name = "${var.name}-home"
  # Holds the account's tools, agent logins, and repos.
  lifecycle {
    prevent_destroy = true
  }
}

resource "docker_volume" "tailscale" {
  name = "${var.name}-tailscale"
  # Holds the tailnet node identity; losing it means logging in again.
  lifecycle {
    prevent_destroy = true
  }
}

resource "docker_volume" "state" {
  name = "${var.name}-state" # SSH host keys (/var/lib/herdr-box)
}

resource "docker_volume" "docker" {
  name = "${var.name}-docker" # inner Docker's data
}

# Docker's image store lives in containerd; like /var/lib/docker it needs a real
# filesystem, since overlayfs cannot nest on the container's overlay root.
resource "docker_volume" "containerd" {
  name = "${var.name}-containerd"
}

resource "docker_container" "box" {
  name     = var.name
  hostname = var.name
  image    = docker_image.box.image_id
  restart  = "unless-stopped"

  # systemd as PID 1 with its own cgroup root, plus Docker and Tailscale inside
  # (/dev/net/tun). No published ports: SSH is reachable over Tailscale only.
  privileged    = true
  cgroupns_mode = "private"
  tmpfs = {
    "/run"      = ""
    "/run/lock" = ""
  }

  volumes {
    volume_name    = docker_volume.home.name
    container_path = "/home"
  }
  volumes {
    volume_name    = docker_volume.tailscale.name
    container_path = "/var/lib/tailscale"
  }
  volumes {
    volume_name    = docker_volume.state.name
    container_path = "/var/lib/herdr-box"
  }
  volumes {
    volume_name    = docker_volume.docker.name
    container_path = "/var/lib/docker"
  }
  volumes {
    volume_name    = docker_volume.containerd.name
    container_path = "/var/lib/containerd"
  }
}
