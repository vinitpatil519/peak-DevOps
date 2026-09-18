output "repository_urls" {
  description = "Map of image name -> repository URL"
  value       = { for k, r in aws_ecr_repository.this : k => r.repository_url }
}

output "repository_arns" {
  description = "Repository ARNs"
  value       = [for r in aws_ecr_repository.this : r.arn]
}

output "registry" {
  description = "Registry hostname"
  value       = split("/", values(aws_ecr_repository.this)[0].repository_url)[0]
}
