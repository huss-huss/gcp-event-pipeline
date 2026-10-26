variable "project_id" {
  description = "Project that owns the topics and subscriptions."
  type        = string
}

variable "name_prefix" {
  description = "Short prefix used in resource names."
  type        = string
}

variable "labels" {
  description = "Labels applied to topics and subscriptions."
  type        = map(string)
  default     = {}
}

variable "raw_bucket_name" {
  description = "Bucket whose OBJECT_FINALIZE events are published."
  type        = string
}

variable "raw_object_prefix" {
  description = "Only objects under this prefix generate notifications."
  type        = string
  default     = "incoming/"
}

variable "kms_key_name" {
  description = "Optional CMEK for the topics. The Pub/Sub service agent must hold encrypter/decrypter on it."
  type        = string
  default     = null
}

variable "topic_message_retention" {
  description = "How long the notification topic retains messages so subscriptions can be replayed with seek (e.g. \"86400s\")."
  type        = string
  default     = "86400s"
}

variable "create_push_subscription" {
  description = "Create the push subscription (with retry policy + dead-lettering) that delivers events to the processor. Set false when an Eventarc trigger consumes the topic instead."
  type        = bool
  default     = true
}

variable "push_endpoint" {
  description = "HTTPS endpoint of the processor (function URL). Required when create_push_subscription is true."
  type        = string
  default     = null
}

variable "push_service_account_email" {
  description = "Service account whose OIDC token Pub/Sub attaches to push requests. Must have run.invoker on the processor."
  type        = string
  default     = null
}

variable "ack_deadline_seconds" {
  description = "Ack deadline for the push subscription. For push this is the HTTP request timeout, so match the function timeout."
  type        = number
  default     = 300

  validation {
    condition     = var.ack_deadline_seconds >= 10 && var.ack_deadline_seconds <= 600
    error_message = "ack_deadline_seconds must be between 10 and 600."
  }
}

variable "minimum_backoff" {
  description = "Minimum delay before a failed delivery is retried."
  type        = string
  default     = "10s"
}

variable "maximum_backoff" {
  description = "Maximum delay between retries (exponential backoff is applied between min and max)."
  type        = string
  default     = "600s"
}

variable "max_delivery_attempts" {
  description = "Delivery attempts before a message is forwarded to the dead-letter topic."
  type        = number
  default     = 5

  validation {
    condition     = var.max_delivery_attempts >= 5 && var.max_delivery_attempts <= 100
    error_message = "Pub/Sub requires max_delivery_attempts between 5 and 100."
  }
}

variable "subscription_message_retention" {
  description = "How long unacknowledged messages are kept on the processing subscription."
  type        = string
  default     = "604800s"
}

variable "dead_letter_retention" {
  description = "How long dead-lettered messages are kept for inspection and replay."
  type        = string
  default     = "604800s"
}
