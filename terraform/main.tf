locals {
  repo = abspath("${path.module}/..")
}

# One box per entry in var.boxes, all on var.docker_host. See versions.tf for adding
# boxes on a second Docker host.
module "box" {
  source   = "./modules/box"
  for_each = var.boxes

  name               = each.key
  source_dir         = local.repo
  box_dir            = "${local.repo}/boxes/${each.key}"
  projects_dir       = each.value.projects_dir
  base_image         = each.value.base_image
  extra_apt_packages = each.value.extra_apt_packages
  limits             = each.value.limits
  extra_mounts       = each.value.extra_mounts
}
