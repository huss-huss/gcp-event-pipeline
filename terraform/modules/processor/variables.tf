variable "project_id" {
  description = "Project that hosts the function."
  type        = string
}

variable "region" {
  description = "Region for the function, its source bucket and (if used) the Eventarc trigger."
  type        = string
}

variable "name_prefix" {
  description = "Short prefix used in resource names."
  type        = string
}

variable "labels" {
  description = "Labels applied to the function and its source bucket."
  type        = map(string)
  default     = {}
}

variable "source_dir" {
  description = "Path to the Python processor source (directory containing main.py and requirements.txt)."
  type        = string
}

variable "runtime" {
  description = "Cloud Functions Python runtime."
  type        = string
  default     = "python312"
}

variable "entry_point" {
  description = "Name of the CloudEvent function in main.py."
  type        = string
  default     = "process_raw_object"
}

variable "raw_bucket_name" {
  description = "Raw bucket the function reads from (granted objectViewer)."
  type        = string
}

variable "curated_bucket_name" {
  description = "Curated bucket the function writes to (granted objectCreator only)."
  type        = string
}

variable "raw_prefix" {
  description = "Object prefix in the raw bucket the processor accepts."
  type        = string
  default     = "incoming/"
}

variable "curated_prefix" {
  description = "Prefix for curated output in the curated bucket."
  type        = string
  default     = "curated/orders"
}

variable "quarantine_prefix" {
  description = "Prefix for rejected records in the curated bucket."
  type        = string
  default     = "quarantine/orders"
}

variable "available_memory" {
  description = "Memory per instance (e.g. \"512Mi\")."
  type        = string
  default     = "512Mi"
}

variable "available_cpu" {
  description = "vCPU per instance (e.g. \"1\")."
  type        = string
  default     = "1"
}

variable "timeout_seconds" {
  description = "Request timeout. Event-driven 2nd gen functions allow at most 540s."
  type        = number
  default     = 300

  validation {
    condition     = var.timeout_seconds >= 1 && var.timeout_seconds <= 540
    error_message = "timeout_seconds must be between 1 and 540 for event-driven functions."
  }
}

variable "min_instance_count" {
  description = "Warm instances kept running (billed while idle). 0 = scale to zero."
  type        = number
  default     = 0
}

variable "max_instance_count" {
  description = "Upper bound on instances; caps cost and downstream pressure."
  type        = number
  default     = 10
}

variable "max_instance_request_concurrency" {
  description = "Concurrent requests per instance. 1 keeps memory predictable for large files."
  type        = number
  default     = 1
}

variable "delivery_mode" {
  description = "\"pubsub_push\": our own push subscription with retry + DLQ invokes the function. \"eventarc\": an Eventarc Pub/Sub trigger on the topic invokes it."
  type        = string
  default     = "pubsub_push"

  validation {
    condition     = contains(["pubsub_push", "eventarc"], var.delivery_mode)
    error_message = "delivery_mode must be \"pubsub_push\" or \"eventarc\"."
  }
}

variable "notification_topic_id" {
  description = "Topic receiving GCS notifications (used by the Eventarc trigger in eventarc mode)."
  type        = string
}

variable "source_object_retention_days" {
  description = "Days to keep uploaded source archives in the source bucket."
  type        = number
  default     = 30
}
