variable "prefix" {
  description = "Globally-unique bucket name prefix, e.g. cloudforge-dev-123456789012"
  type        = string
}

variable "buckets" {
  description = "Buckets to create (key = suffix)"
  type = map(object({
    purpose     = string
    expire_days = number
    versioning  = optional(bool, true)
  }))
}

variable "force_destroy" {
  description = "Allow destroying non-empty buckets (demo environments only)"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags"
  type        = map(string)
  default     = {}
}
