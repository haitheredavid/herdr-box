output "container" {
  value = docker_container.box.name
}

output "box_user" {
  value = local.box_user
}

output "image_id" {
  value = docker_image.box.image_id
}

output "ssh_config" {
  description = "ssh_config stanza for this box (MagicDNS name)."
  value       = <<-EOT
    Host ${var.name}
      HostName ${var.name}
      User ${coalesce(local.box_user, "UNKNOWN")}
  EOT
}
