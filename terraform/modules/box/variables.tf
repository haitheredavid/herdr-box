variable "name" {
  description = "Container name, hostname, and Tailscale machine name; prefix for volume names."
  type        = string
}

variable "source_dir" {
  description = "herdr-box repo root: the image build context."
  type        = string
}

variable "box_dir" {
  description = "This box's config directory (box.conf, and optionally authorized_keys and env)."
  type        = string
}

variable "projects_dir" {
  description = "Directory on the Docker host bind-mounted at ~/projects on the box. null: projects live in the home volume."
  type        = string
  default     = null
}

variable "base_image" {
  description = "Image the box image builds FROM. null: the Dockerfile's default (ubuntu:24.04)."
  type        = string
  default     = null
}

variable "extra_apt_packages" {
  description = "Extra apt packages baked into the image."
  type        = list(string)
  default     = []
}

variable "limits" {
  description = "Resource limits: memory and shm_size in MB (shm_size default 1024), cpus as a decimal string (e.g. \"2.5\")."
  type = object({
    memory   = optional(number)
    cpus     = optional(string)
    shm_size = optional(number)
  })
  default = {}
}

variable "extra_mounts" {
  description = "Additional bind mounts from the Docker host."
  type = list(object({
    host_path      = string
    container_path = string
    read_only      = optional(bool, false)
  }))
  default = []
}
