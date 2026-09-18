variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes minor version (must be in EKS standard support)"
  type        = string
  default     = "1.34"
}

variable "cluster_role_arn" {
  description = "IAM role for the control plane"
  type        = string
}

variable "node_role_arn" {
  description = "IAM role for worker nodes"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnets for the control plane ENIs and nodes"
  type        = list(string)
}

variable "cluster_security_group_id" {
  description = "Additional security group for the control plane"
  type        = string
}

variable "node_security_group_id" {
  description = "Security group for worker nodes"
  type        = string
}

variable "endpoint_public_access" {
  description = "Expose the Kubernetes API publicly (restricted by CIDR)"
  type        = bool
  default     = true
}

variable "endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach the public API endpoint (set to your office/VPN IP)"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "service_cidr" {
  description = "Kubernetes Service CIDR"
  type        = string
  default     = "172.20.0.0/16"
}

variable "log_retention_days" {
  description = "CloudWatch retention for control-plane logs"
  type        = number
  default     = 14
}

variable "admin_principal_arns" {
  description = "IAM roles/users granted cluster-admin through EKS access entries"
  type        = list(string)
  default     = []
}

variable "developer_principal_arns" {
  description = "IAM roles/users mapped to the cloudforge:developers Kubernetes group"
  type        = list(string)
  default     = []
}

variable "node_groups" {
  description = "Managed node groups"
  type = map(object({
    instance_types = list(string)
    capacity_type  = optional(string, "ON_DEMAND")
    ami_type       = optional(string, "AL2023_x86_64_STANDARD")
    min_size       = number
    max_size       = number
    desired_size   = number
    disk_size      = optional(number, 40)
    labels         = optional(map(string), {})
    taints = optional(list(object({
      key    = string
      value  = string
      effect = string
    })), [])
  }))
}

variable "pod_identity_roles" {
  description = "Controller service accounts to bind to IAM roles via EKS Pod Identity"
  type = map(object({
    namespace       = string
    service_account = string
    role_arn        = string
  }))
  default = {}
}

variable "tags" {
  description = "Tags"
  type        = map(string)
  default     = {}
}
