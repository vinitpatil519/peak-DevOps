variable "domain" {
  description = "DNS zone, e.g. cloudforge.example.com"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "create_zone" {
  description = "Create the hosted zone (true) or use an existing one (false)"
  type        = bool
  default     = true
}

variable "manage_caa" {
  description = "Create a CAA record restricting certificate issuers"
  type        = bool
  default     = true
}

variable "security_contact" {
  description = "Email for CAA iodef reports"
  type        = string
  default     = "security@example.com"
}

variable "force_destroy" {
  description = "Delete all records when destroying the zone"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags"
  type        = map(string)
  default     = {}
}
