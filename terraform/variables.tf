variable "docker_host" {
  description = "Docker daemon to run the boxes on, e.g. ssh://me@machine. null uses DOCKER_HOST or the local socket."
  type        = string
  default     = null
}

variable "boxes" {
  description = "Boxes on this Docker host, keyed by name (container, hostname, Tailscale machine name, volume prefix). Each box's config lives in boxes/<name>/."
  type = map(object({
    projects_dir       = optional(string)
    base_image         = optional(string)
    extra_apt_packages = optional(list(string), [])
    limits = optional(object({
      memory   = optional(number)
      cpus     = optional(string)
      shm_size = optional(number)
    }), {})
    extra_mounts = optional(list(object({
      host_path      = string
      container_path = string
      read_only      = optional(bool, false)
    })), [])
  }))
  default = { "herdr-box" = {} }

  validation {
    condition     = alltrue([for k in keys(var.boxes) : can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", k))])
    error_message = "Box names must be valid hostnames: lowercase letters, digits, and hyphens, not starting or ending with a hyphen, at most 63 characters."
  }
}
