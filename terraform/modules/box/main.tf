locals {
  box_conf = "${var.box_dir}/box.conf"
  # null when box.conf is missing or has no BOX_USER; the container precondition reports it.
  box_user = try(regex("(?m)^[[:space:]]*BOX_USER=[\"']?([^\"'[:space:]]+)", file(local.box_conf))[0], null)

  # The image rebuilds when anything baked into it changes; containers pick it up only
  # on an explicit `mise run tf:replace -- <box>`.
  image_files = sort([
    for f in setunion(
      fileset(var.source_dir, "bootstrap/**"),
      fileset(var.source_dir, "config/**"),
      fileset(var.source_dir, "image/**"),
    ) : f if !endswith(f, ".DS_Store")
  ])
  image_hash = sha1(join("\n", concat(
    [for f in local.image_files : "${f}:${filesha1("${var.source_dir}/${f}")}"],
    [join(" ", var.extra_apt_packages)],
  )))

  # Per-box config copied into the container at create time.
  uploads = {
    for f in ["box.conf", "authorized_keys", "env"] : f => "${var.box_dir}/${f}"
    if fileexists("${var.box_dir}/${f}")
  }

  projects = var.projects_dir == null ? null : abspath(pathexpand(var.projects_dir))
}

resource "docker_image" "box" {
  name = "${var.name}:latest"
  # Running containers keep using the previous image until replaced; never delete it.
  # (No create_before_destroy: the container depends on this image and is replaced
  # destroy-first, which would make a cycle.)
  keep_locally = true

  build {
    context    = var.source_dir
    dockerfile = "image/Dockerfile"
    build_args = merge(
      {
        EXTRA_APT_PACKAGES = join(" ", var.extra_apt_packages)
        BUILD_HASH         = local.image_hash
      },
      var.base_image == null ? {} : { BASE = var.base_image },
    )
    label = {
      "herdr-box.name" = var.name
    }
  }

  triggers = {
    image_hash = local.image_hash
    base       = coalesce(var.base_image, "ubuntu:24.04")
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
  # New host keys mean "host key changed" warnings on every client.
  lifecycle {
    prevent_destroy = true
  }
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

  memory   = var.limits.memory
  cpus     = var.limits.cpus
  shm_size = coalesce(var.limits.shm_size, 1024) # headless browsers need more than 64 MB

  # Give systemd time to shut down cleanly (STOPSIGNAL SIGRTMIN+3).
  stop_timeout          = 60
  destroy_grace_seconds = 60

  healthcheck {
    # One unit at a time: `systemctl is-active a b c` succeeds when any one is active.
    test = [
      "CMD-SHELL",
      "for u in herdr-box-early herdr-box-bootstrap ssh docker tailscaled; do systemctl is-active --quiet $u.service || exit 1; done",
    ]
    interval     = "30s"
    timeout      = "10s"
    start_period = "20m"
    retries      = 3
  }
  # First boot on an empty home installs every toolchain; wait for the bootstrap and
  # services to be healthy, so a failed bootstrap fails the apply.
  wait         = true
  wait_timeout = 1500

  dynamic "upload" {
    for_each = local.uploads
    content {
      file   = "/opt/herdr-box/box/${upload.key}"
      source = upload.value
      # Re-upload (replace) when the content changes.
      source_hash = filesha1(upload.value)
    }
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
  # Your projects, shared live with the Docker host. Docker Desktop shows bind-mounted
  # files as owned by whichever user reads them, so the box user owns them.
  dynamic "volumes" {
    for_each = local.projects == null ? [] : [local.projects]
    content {
      host_path      = volumes.value
      container_path = "/home/${local.box_user}/projects"
    }
  }
  dynamic "volumes" {
    for_each = var.extra_mounts
    content {
      host_path      = abspath(pathexpand(volumes.value.host_path))
      container_path = volumes.value.container_path
      read_only      = volumes.value.read_only
    }
  }

  lifecycle {
    # Image rebuilds and config edits don't recreate the box on their own; replace it
    # deliberately (`mise run tf:replace -- <box>`) to pick them up.
    ignore_changes = [image, upload]

    precondition {
      condition     = local.box_user != null
      error_message = "missing or invalid BOX_USER in ${local.box_conf}"
    }
  }
}
