variable "project_id" {
  description = "Project that owns the buckets."
  type        = string
}

variable "name_prefix" {
  description = "Short prefix used in resource names, e.g. \"evp-dev\"."
  type        = string
}

variable "location" {
  description = "Bucket location (region or multi-region). Keep it in the function's region to avoid egress."
  type        = string
}

variable "labels" {
  description = "Labels applied to every bucket."
  type        = map(string)
  default     = {}
}

variable "kms_key_name" {
  description = "Optional Cloud KMS key (projects/.../cryptoKeys/...) used as the default CMEK for both buckets. Null = Google-managed encryption."
  type        = string
  default     = null
}

variable "force_destroy" {
  description = "Allow Terraform to delete non-empty buckets. Keep false outside throwaway environments."
  type        = bool
  default     = false
}

variable "raw_nearline_after_days" {
  description = "Age in days after which raw objects move to NEARLINE storage."
  type        = number
  default     = 30
}

variable "raw_delete_after_days" {
  description = "Age in days after which raw objects are deleted (0 disables deletion)."
  type        = number
  default     = 365
}

variable "noncurrent_version_retention_days" {
  description = "Days to keep noncurrent (overwritten/deleted) object versions before permanent deletion."
  type        = number
  default     = 30
}

variable "quarantine_prefix" {
  description = "Prefix (in the curated bucket) holding rejected records."
  type        = string
  default     = "quarantine/"
}

variable "quarantine_delete_after_days" {
  description = "Age in days after which quarantined records are deleted."
  type        = number
  default     = 90
}
