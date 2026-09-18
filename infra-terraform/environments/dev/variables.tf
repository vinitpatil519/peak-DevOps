variable "project" {
  description = "Project name (resource prefix)"
  type        = string
  default     = "cloudforge"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "VPC CIDR"
  type        = string
  default     = "10.40.0.0/16"
}

variable "az_count" {
  description = "Availability zones"
  type        = number
  default     = 3
}

variable "single_nat_gateway" {
  description = "One shared NAT gateway (cost) vs one per AZ (resilience)"
  type        = bool
  default     = true
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.34"
}

variable "api_allowed_cidrs" {
  description = "CIDRs allowed to reach the public EKS API endpoint"
  type        = list(string)
}

variable "admin_principal_arns" {
  description = "IAM principals with cluster-admin"
  type        = list(string)
  default     = []
}

variable "developer_principal_arns" {
  description = "IAM principals mapped to cloudforge:developers"
  type        = list(string)
  default     = []
}

variable "system_instance_types" {
  description = "Instance types for the system node group"
  type        = list(string)
  default     = ["t3.large"]
}

variable "app_instance_types" {
  description = "Instance types for the app node group"
  type        = list(string)
  default     = ["t3.large", "t3a.large", "m6i.large"]
}

variable "app_capacity_type" {
  description = "ON_DEMAND or SPOT for the app node group"
  type        = string
  default     = "SPOT"
}

variable "domain" {
  description = "Public DNS zone for the platform"
  type        = string
  default     = "cloudforge.example.com"
}

variable "create_dns_zone" {
  description = "Create the Route53 zone (false = use existing)"
  type        = bool
  default     = true
}

variable "demo_mode" {
  description = "Allow force-destroy of buckets/repos/zones/secrets for short-lived demos"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Extra tags"
  type        = map(string)
  default     = {}
}
