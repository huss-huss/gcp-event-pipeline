data "google_project" "this" {
  project_id = var.project_id
}

resource "google_monitoring_notification_channel" "email" {
  for_each = toset(var.alert_emails)

  project      = var.project_id
  display_name = "${var.name_prefix} alerts: ${each.value}"
  type         = "email"
  labels = {
    email_address = each.value
  }
}

locals {
  channels = [for c in google_monitoring_notification_channel.email : c.id]
}

# ---------------------------------------------------------------------------
# Function failures (log-based metric -> alert)
# ---------------------------------------------------------------------------
resource "google_logging_metric" "processor_errors" {
  project     = var.project_id
  name        = "${var.name_prefix}-processor-errors"
  description = "ERROR+ log entries from the event processor (invalid events, processing failures, crashes)."
  filter      = <<-EOT
    resource.type="cloud_run_revision"
    resource.labels.service_name="${var.service_name}"
    severity>=ERROR
  EOT

  metric_descriptor {
    metric_kind  = "DELTA"
    value_type   = "INT64"
    unit         = "1"
    display_name = "${var.name_prefix} processor errors"

    labels {
      key         = "event"
      value_type  = "STRING"
      description = "Structured log 'event' field (invalid_event, processing_failed, ...)."
    }
  }

  label_extractors = {
    event = "EXTRACT(jsonPayload.event)"
  }
}

resource "google_monitoring_alert_policy" "processor_errors" {
  project               = var.project_id
  display_name          = "${var.name_prefix}: processor errors"
  combiner              = "OR"
  notification_channels = local.channels
  severity              = "ERROR"

  conditions {
    display_name = "Processor logged errors"
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.processor_errors.name}\" AND resource.type=\"cloud_run_revision\""
      comparison      = "COMPARISON_GT"
      threshold_value = var.error_threshold
      duration        = "0s"

      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_SUM"
        cross_series_reducer = "REDUCE_SUM"
      }

      trigger {
        count = 1
      }
    }
  }

  alert_strategy {
    auto_close = "1800s"
  }

  documentation {
    mime_type = "text/markdown"
    content   = "The processor logged errors. Filter logs by `jsonPayload.event` (`invalid_event`, `processing_failed`). Transient failures are retried by Pub/Sub; persistent ones end up in the dead-letter subscription."
  }
}

# ---------------------------------------------------------------------------
# Dead-letter backlog and processing lag
# ---------------------------------------------------------------------------
resource "google_monitoring_alert_policy" "dead_letter_backlog" {
  count = var.enable_subscription_alerts ? 1 : 0

  project               = var.project_id
  display_name          = "${var.name_prefix}: dead-letter backlog"
  combiner              = "OR"
  notification_channels = local.channels
  severity              = "CRITICAL"

  conditions {
    display_name = "Messages waiting in the dead-letter subscription"
    condition_threshold {
      filter          = "metric.type=\"pubsub.googleapis.com/subscription/num_undelivered_messages\" AND resource.type=\"pubsub_subscription\" AND resource.labels.subscription_id=\"${coalesce(var.dead_letter_subscription_name, "unset")}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "300s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MAX"
      }

      trigger {
        count = 1
      }
    }
  }

  documentation {
    mime_type = "text/markdown"
    content   = "Events exhausted their delivery attempts. Inspect with `gcloud pubsub subscriptions pull ${coalesce(var.dead_letter_subscription_name, "unset")} --limit=10`, fix the cause, then re-publish to the notification topic. Processing is idempotent, so replays are safe."
  }

  lifecycle {
    precondition {
      condition     = var.dead_letter_subscription_name != null
      error_message = "dead_letter_subscription_name is required when enable_subscription_alerts is true."
    }
  }
}

resource "google_monitoring_alert_policy" "processing_lag" {
  count = var.enable_subscription_alerts ? 1 : 0

  project               = var.project_id
  display_name          = "${var.name_prefix}: processing lag"
  combiner              = "OR"
  notification_channels = local.channels
  severity              = "WARNING"

  conditions {
    display_name = "Oldest unacked notification is too old"
    condition_threshold {
      filter          = "metric.type=\"pubsub.googleapis.com/subscription/oldest_unacked_message_age\" AND resource.type=\"pubsub_subscription\" AND resource.labels.subscription_id=\"${coalesce(var.processor_subscription_name, "unset")}\""
      comparison      = "COMPARISON_GT"
      threshold_value = var.backlog_age_threshold_seconds
      duration        = "300s"

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MAX"
      }

      trigger {
        count = 1
      }
    }
  }

  lifecycle {
    precondition {
      condition     = var.processor_subscription_name != null
      error_message = "processor_subscription_name is required when enable_subscription_alerts is true."
    }
  }
}

# ---------------------------------------------------------------------------
# Billing budget
# ---------------------------------------------------------------------------
resource "google_billing_budget" "project" {
  count = var.billing_account == null ? 0 : 1

  billing_account = var.billing_account
  display_name    = "${var.name_prefix} monthly budget"

  budget_filter {
    projects               = ["projects/${data.google_project.this.number}"]
    credit_types_treatment = "INCLUDE_ALL_CREDITS"
    calendar_period        = "MONTH"
  }

  amount {
    specified_amount {
      currency_code = var.budget_currency
      units         = tostring(var.budget_amount)
    }
  }

  dynamic "threshold_rules" {
    for_each = var.budget_thresholds
    content {
      threshold_percent = threshold_rules.value
      spend_basis       = "CURRENT_SPEND"
    }
  }

  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "FORECASTED_SPEND"
  }

  all_updates_rule {
    monitoring_notification_channels = local.channels
    disable_default_iam_recipients   = false
  }
}
