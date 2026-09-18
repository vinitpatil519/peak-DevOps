variable "name" {
  description = "Name prefix"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name (scopes the autoscaler policy)"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "lb_controller_version" {
  description = "AWS Load Balancer Controller release tag whose IAM policy to use"
  type        = string
  default     = "v2.14.0"
}

variable "route53_zone_ids" {
  description = "Hosted zones ExternalDNS / cert-manager may modify"
  type        = list(string)
  default     = []
}

variable "secrets_prefix" {
  description = "Secrets Manager name prefix the External Secrets Operator may read"
  type        = string
}

variable "loki_bucket_arn" {
  description = "S3 bucket ARN for Loki chunks (null to skip)"
  type        = string
  default     = null
}

variable "ecr_repository_arns" {
  description = "ECR repositories CI may push to"
  type        = list(string)
}

variable "tags" {
  description = "Tags"
  type        = map(string)
  default     = {}
}

# Plain booleans (not derived from resource attributes) so `count` is known at plan time.
variable "enable_dns_policies" {
  description = "Grant ExternalDNS/cert-manager access to route53_zone_ids"
  type        = bool
  default     = true
}

variable "enable_loki_policy" {
  description = "Grant Loki access to loki_bucket_arn"
  type        = bool
  default     = true
}
