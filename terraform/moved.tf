# State moves from the single-box layout (root resources) to module.box. Forks that
# used another `name` should change the "herdr-box" key to that name before applying.
# The old docker_image.dotfiles has no counterpart and is destroyed.
moved {
  from = docker_image.box
  to   = module.box["herdr-box"].docker_image.box
}

moved {
  from = docker_volume.home
  to   = module.box["herdr-box"].docker_volume.home
}

moved {
  from = docker_volume.tailscale
  to   = module.box["herdr-box"].docker_volume.tailscale
}

moved {
  from = docker_volume.state
  to   = module.box["herdr-box"].docker_volume.state
}

moved {
  from = docker_volume.docker
  to   = module.box["herdr-box"].docker_volume.docker
}

moved {
  from = docker_volume.containerd
  to   = module.box["herdr-box"].docker_volume.containerd
}

moved {
  from = docker_container.box
  to   = module.box["herdr-box"].docker_container.box
}
