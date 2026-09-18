variable "name" {
  description = "Name prefix for VPC resources"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name (used for subnet discovery tags)"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.40.0.0/16"
  validation {
    condition     = can(cidrhost(var.cidr, 0)) && tonumber(split("/", var.cidr)[1]) <= 16
    error_message = "cidr must be a valid IPv4 CIDR of /16 or larger."
  }
}

variable "az_count" {
  description = "Number of availability zones (2-3)"
  type        = number
  default     = 3
  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3."
  }
}

variable "single_nat_gateway" {
  description = "Use one NAT gateway for all AZs (cheaper, not AZ-fault-tolerant)"
  type        = bool
  default     = true
}

variable "enable_flow_logs" {
  description = "Enable VPC flow logs to CloudWatch"
  type        = bool
  default     = true
}

variable "flow_logs_traffic_type" {
  description = "ACCEPT, REJECT or ALL"
  type        = string
  default     = "REJECT"
}

variable "flow_logs_retention_days" {
  description = "CloudWatch retention for flow logs"
  type        = number
  default     = 14
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default     = {}
}
