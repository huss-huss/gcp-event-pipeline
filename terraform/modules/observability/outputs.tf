output "log_metric_name" {
  description = "Name of the processor error log-based metric."
  value       = google_logging_metric.processor_errors.name
}

output "alert_policy_ids" {
  description = "IDs of the alert policies created."
  value = concat(
    [google_monitoring_alert_policy.processor_errors.id],
    google_monitoring_alert_policy.dead_letter_backlog[*].id,
    google_monitoring_alert_policy.processing_lag[*].id,
  )
}

output "budget_id" {
  description = "Billing budget ID (null when no billing account is configured)."
  value       = one(google_billing_budget.project[*].id)
}
