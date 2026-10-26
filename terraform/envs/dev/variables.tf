variable "project_id" {
  description = "GCP project ID to deploy into."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be a valid GCP project ID (6-30 chars, lowercase letters, digits, hyphens)."
  }
}

variable "region" {
  description = "Region for buckets, function and trigger. Buckets are regional to keep reads/writes egress-free."
  type        = string
  default     = "europe-west1"

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]$", var.region))
    error_message = "region must look like \"europe-west1\" (multi-regions are not supported for Cloud Functions)."
  }
}

variable "environment" {
  description = "Environment name; used in resource names and labels."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of dev, staging, prod."
  }
}

variable "name" {
  description = "Short application name used as resource name prefix (combined with environment)."
  type        = string
  default     = "evp"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,7}$", var.name))
    error_message = "name must be 2-8 lowercase alphanumerics starting with a letter (service account IDs are limited to 30 chars)."
  }
}

variable "delivery_mode" {
  description = "How events reach the function: \"pubsub_push\" (own subscription with exponential backoff + dead-letter topic; recommended) or \"eventarc\" (Eventarc Pub/Sub trigger; Eventarc-managed retries, no DLQ)."
  type        = string
  default     = "pubsub_push"

  validation {
    condition     = contains(["pubsub_push", "eventarc"], var.delivery_mode)
    error_message = "delivery_mode must be \"pubsub_push\" or \"eventarc\"."
  }
}

variable "kms_key_name" {
  description = "Optional CMEK (projects/P/locations/L/keyRings/R/cryptoKeys/K) for buckets. Must be in the bucket location."
  type        = string
  default     = null

  validation {
    condition     = var.kms_key_name == null || can(regex("^projects/[^/]+/locations/[^/]+/keyRings/[^/]+/cryptoKeys/[^/]+$", var.kms_key_name))
    error_message = "kms_key_name must be a full Cloud KMS crypto key resource name."
  }
}

variable "force_destroy_buckets" {
  description = "Allow `terraform destroy` to delete non-empty data buckets. Only for disposable environments."
  type        = bool
  default     = false
}

variable "raw_object_prefix" {
  description = "Producers upload JSONL files under this prefix of the raw bucket."
  type        = string
  default     = "incoming/"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9_-]*/$", var.raw_object_prefix))
    error_message = "raw_object_prefix must be a simple prefix ending in \"/\", e.g. \"incoming/\"."
  }
}

variable "max_delivery_attempts" {
  description = "Delivery attempts before a notification is dead-lettered (Pub/Sub allows 5-100)."
  type        = number
  default     = 5

  validation {
    condition     = var.max_delivery_attempts >= 5 && var.max_delivery_attempts <= 100
    error_message = "max_delivery_attempts must be between 5 and 100."
  }
}

variable "function_timeout_seconds" {
  description = "Function timeout; also used as the push subscription ack deadline."
  type        = number
  default     = 300

  validation {
    condition     = var.function_timeout_seconds >= 10 && var.function_timeout_seconds <= 540
    error_message = "function_timeout_seconds must be between 10 and 540."
  }
}

variable "function_memory" {
  description = "Memory per function instance."
  type        = string
  default     = "512Mi"

  validation {
    condition     = can(regex("^[0-9]+(Mi|Gi)$", var.function_memory))
    error_message = "function_memory must be like \"512Mi\" or \"1Gi\"."
  }
}

variable "min_instances" {
  description = "Minimum warm instances (0 = scale to zero; >0 is billed while idle)."
  type        = number
  default     = 0

  validation {
    condition     = var.min_instances >= 0 && var.min_instances <= 5
    error_message = "min_instances must be between 0 and 5."
  }
}

variable "max_instances" {
  description = "Maximum instances; the main cost and blast-radius control."
  type        = number
  default     = 10

  validation {
    condition     = var.max_instances >= 1 && var.max_instances <= 100
    error_message = "max_instances must be between 1 and 100."
  }
}

variable "alert_emails" {
  description = "Email addresses for alert and budget notifications."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for e in var.alert_emails : can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", e))])
    error_message = "alert_emails must contain valid email addresses."
  }
}

variable "billing_account" {
  description = "Billing account ID for the budget (XXXXXX-XXXXXX-XXXXXX). Null skips the budget."
  type        = string
  default     = null

  validation {
    condition     = var.billing_account == null || can(regex("^[A-F0-9]{6}-[A-F0-9]{6}-[A-F0-9]{6}$", var.billing_account))
    error_message = "billing_account must look like 0X0X0X-0X0X0X-0X0X0X."
  }
}

variable "monthly_budget" {
  description = "Monthly budget amount in the billing account currency."
  type        = number
  default     = 25

  validation {
    condition     = var.monthly_budget > 0
    error_message = "monthly_budget must be positive."
  }
}
