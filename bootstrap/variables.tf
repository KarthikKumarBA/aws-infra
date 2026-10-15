variable "region" {
  description = "AWS region for the state bucket and the cluster"
  type        = string
  default     = "ap-south-1"
}

variable "project" {
  description = "Prefix for resource names"
  type        = string
  default     = "karthik-platform"
}

variable "github_owner" {
  description = "GitHub user or organization that owns the repositories"
  type        = string
}

variable "infra_repo" {
  description = "Name of this infrastructure repository on GitHub"
  type        = string
  default     = "aws-infra"
}

variable "allow_state_bucket_destroy" {
  description = "Set true only for destroy: lets Terraform delete the state bucket including all object versions"
  type        = bool
  default     = false
}
