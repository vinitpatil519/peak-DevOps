variable "prefix" {
  description = "Repository namespace, e.g. cloudforge -> cloudforge/api"
  type        = string
}

variable "repositories" {
  description = "Repository names under the prefix"
  type        = list(string)
  default     = ["api", "web", "apache-proxy"]
}

variable "keep_images" {
  description = "Tagged images to retain per repository"
  type        = number
  default     = 30
}

variable "force_delete" {
  description = "Allow destroying repositories that still contain images (demo environments)"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags"
  type        = map(string)
  default     = {}
}
