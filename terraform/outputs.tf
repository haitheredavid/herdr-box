output "container" {
  value = docker_container.box.name
}

output "ssh_config" {
  description = "Add to ~/.ssh/config on any machine in your tailnet (MagicDNS name)."
  value       = <<-EOT
    Host ${var.name}
      HostName ${var.name}
      User ${local.box_user}
  EOT
}
