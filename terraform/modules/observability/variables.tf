variable "project_id" {
  description = "Project to monitor."
  type        = string
}

variable "name_prefix" {
  description = "Short prefix used in resource names."
  type        = string
}

variable "service_name" {
  description = "Cloud Run service name backing the processor function."
  type        = string
}

variable "processor_subscription_name" {
  description = "Push subscription feeding the processor; enables the backlog-age alert. Null to disable."
  type        = string
  default     = null
}

variable "dead_letter_subscription_name" {
  description = "Subscription on the dead-letter topic; enables the DLQ backlog alert. Null to disable."
  type        = string
  default     = null
}

variable "enable_subscription_alerts" {
  description = "Whether the subscription-based alerts are created (must be known at plan time, unlike the names)."
  type        = bool
  default     = true
}

variable "alert_emails" {
  description = "Email addresses notified by alert policies and budget thresholds."
  type        = list(string)
  default     = []
}

variable "error_threshold" {
  description = "Alert when more than this many processor errors are logged in 5 minutes."
  type        = number
  default     = 0
}

variable "backlog_age_threshold_seconds" {
  description = "Alert when the oldest unacked message on the processing subscription is older than this."
  type        = number
  default     = 1800
}

variable "billing_account" {
  description = "Billing account ID (XXXXXX-XXXXXX-XXXXXX) for the budget. Null skips the budget."
  type        = string
  default     = null
}

variable "budget_amount" {
  description = "Monthly budget in whole currency units."
  type        = number
  default     = 25
}

variable "budget_currency" {
  description = "Currency of the budget amount; must match the billing account currency."
  type        = string
  default     = "USD"
}

variable "budget_thresholds" {
  description = "Fractions of the budget (actual spend) that trigger notifications."
  type        = list(number)
  default     = [0.5, 0.9, 1.0]
}
