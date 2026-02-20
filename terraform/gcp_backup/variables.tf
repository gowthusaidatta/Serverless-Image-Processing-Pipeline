variable "project_id" {
  description = "Your GCP Project ID (e.g. my-project-123456)"
  type        = string
}

variable "region" {
  description = "GCP region for all resources"
  type        = string
  default     = "us-central1"
}
