variable "project_id" {
  type        = string
  description = "GCP project that hosts the VM. Billing must be enabled."
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "zone" {
  type    = string
  default = "us-central1-a"
}

variable "name" {
  type        = string
  default     = "paid-media-agent"
  description = "Prefix for every resource and the VM name."
}

variable "machine_type" {
  type        = string
  default     = "e2-small"
  description = "e2-small (2 GB) fits the API, Slack worker, and Postgres with swap. Use e2-medium for headroom."
}

variable "disk_size_gb" {
  type    = number
  default = 20
}

variable "snapshot_retention_days" {
  type    = number
  default = 14
}

variable "deletion_protection" {
  type        = bool
  default     = false
  description = "Set true once the deployment matters; terraform destroy then requires flipping it back."
}

variable "repo_url" {
  type        = string
  default     = "https://github.com/langchain-ai/paid-media-agent.git"
  description = "Git repository the VM clones. Point at your fork to deploy your own changes."
}

variable "repo_ref" {
  type        = string
  default     = "main"
  description = "Branch, tag, or commit the VM checks out."
}
