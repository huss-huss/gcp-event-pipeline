mock_provider "google" {
  mock_data "google_project" {
    defaults = {
      number = "123456789012"
    }
  }
}

variables {
  project_id                    = "demo-project"
  name_prefix                   = "evp-test"
  service_name                  = "evp-test-processor"
  processor_subscription_name   = "evp-test-raw-object-events-processor"
  dead_letter_subscription_name = "evp-test-raw-object-events-dlq-sub"
  alert_emails                  = ["oncall@example.com"]
}

run "alerts" {
  command = plan

  assert {
    condition     = strcontains(google_logging_metric.processor_errors.filter, "resource.labels.service_name=\"evp-test-processor\"") && strcontains(google_logging_metric.processor_errors.filter, "severity>=ERROR")
    error_message = "Log metric must count ERROR entries of the processor service only."
  }

  assert {
    condition     = strcontains(google_monitoring_alert_policy.dead_letter_backlog[0].conditions[0].condition_threshold[0].filter, "subscription_id=\"evp-test-raw-object-events-dlq-sub\"")
    error_message = "DLQ alert must watch the dead-letter subscription."
  }

  assert {
    condition     = google_monitoring_alert_policy.dead_letter_backlog[0].conditions[0].condition_threshold[0].threshold_value == 0
    error_message = "Any dead-lettered message should alert."
  }

  assert {
    condition     = length(google_monitoring_notification_channel.email) == 1
    error_message = "One email channel expected."
  }

  assert {
    condition     = length(google_billing_budget.project) == 0
    error_message = "No budget without a billing account."
  }
}

run "budget" {
  command = plan

  variables {
    billing_account = "000000-AAAAAA-BBBBBB"
    budget_amount   = 40
  }

  assert {
    condition     = google_billing_budget.project[0].amount[0].specified_amount[0].units == "40"
    error_message = "Budget amount must be passed through."
  }

  assert {
    condition = (
      [for r in google_billing_budget.project[0].threshold_rules : r.threshold_percent if r.spend_basis == "CURRENT_SPEND"] == [0.5, 0.9, 1.0] &&
      length([for r in google_billing_budget.project[0].threshold_rules : r if r.spend_basis == "FORECASTED_SPEND"]) == 1
    )
    error_message = "Budget must alert at 50/90/100% actual and 100% forecasted spend."
  }

  assert {
    condition     = google_billing_budget.project[0].budget_filter[0].projects == toset(["projects/123456789012"])
    error_message = "Budget must be scoped to this project."
  }
}

run "no_subscription_alerts_in_eventarc_mode" {
  command = plan

  variables {
    enable_subscription_alerts    = false
    processor_subscription_name   = null
    dead_letter_subscription_name = null
  }

  assert {
    condition     = length(google_monitoring_alert_policy.dead_letter_backlog) == 0 && length(google_monitoring_alert_policy.processing_lag) == 0
    error_message = "Subscription alerts must be skipped without subscriptions."
  }
}
