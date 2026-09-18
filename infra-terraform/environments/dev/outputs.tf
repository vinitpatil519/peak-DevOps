output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint"
  value       = module.eks.cluster_endpoint
}

output "kubeconfig_command" {
  description = "Configure kubectl"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name} --alias cloudforge-eks"
}

output "vpc_id" {
  description = "VPC ID (aws-load-balancer-controller values)"
  value       = module.vpc.vpc_id
}

output "ecr_registry" {
  description = "ECR registry host (Jenkins REGISTRY for TARGET_ENV=eks)"
  value       = module.ecr.registry
}

output "ecr_repository_urls" {
  description = "Image repositories"
  value       = module.ecr.repository_urls
}

output "ci_ecr_push_policy_arn" {
  description = "Attach to the Jenkins IAM principal"
  value       = module.iam.ci_ecr_push_policy_arn
}

output "route53_zone_id" {
  description = "Hosted zone ID (cert-manager dns01 / platform values)"
  value       = module.route53.zone_id
}

output "route53_name_servers" {
  description = "Delegate these NS records at your registrar"
  value       = module.route53.name_servers
}

output "loki_bucket" {
  description = "Loki chunk bucket (monitoring/loki/values-eks.yaml)"
  value       = module.s3.bucket_names["loki"]
}

output "backup_bucket" {
  description = "PostgreSQL backup bucket"
  value       = module.s3.bucket_names["backups"]
}

output "app_secret_name" {
  description = "Secrets Manager secret consumed by ExternalSecrets"
  value       = aws_secretsmanager_secret.app.name
}

output "nat_public_ips" {
  description = "Cluster egress IPs"
  value       = module.vpc.nat_public_ips
}
