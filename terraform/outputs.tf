output "containers" {
  description = "Container name per box."
  value       = { for k, b in module.box : k => b.container }
}

output "box_users" {
  description = "BOX_USER per box."
  value       = { for k, b in module.box : k => b.box_user }
}

output "ssh_config" {
  description = "Add to ~/.ssh/config on any machine in your tailnet (MagicDNS names)."
  value       = join("\n", [for k in sort(keys(module.box)) : module.box[k].ssh_config])
}
