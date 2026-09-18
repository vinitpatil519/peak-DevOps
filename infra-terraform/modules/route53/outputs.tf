output "zone_id" {
  description = "Hosted zone ID"
  value       = local.zone_id
}

output "name_servers" {
  description = "Delegate these NS records from the parent domain/registrar"
  value       = local.name_servers
}
