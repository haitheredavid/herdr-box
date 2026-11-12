variable "name" {
  description = "Container name, hostname, and Tailscale machine name; prefix for volume names."
  type        = string
  default     = "herdr-box"
}

variable "docker_host" {
  description = "Docker daemon to run the box on, e.g. ssh://me@machine. null uses DOCKER_HOST or the local socket."
  type        = string
  default     = null
}

variable "dotfiles_dir" {
  description = "Dotfiles checkout with linux/Dockerfile; the box image builds on it. Empty: plain Ubuntu 24.04."
  type        = string
  default     = ""
}

variable "projects_dir" {
  description = "Directory on the Docker host bind-mounted at ~/projects on the box (e.g. your Mac's ~/projects). Empty: projects live in the home volume."
  type        = string
  default     = ""
}
