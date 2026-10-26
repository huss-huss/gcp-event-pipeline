# Plans the whole environment against a mocked Google provider: proves the
# module wiring is acyclic and that root variables validate input correctly.
# No credentials or API calls are needed.

mock_provider "google" {
  mock_data "google_project" {
    override_during = plan
    defaults = {
      number = "123456789012"
    }
  }

  mock_data "google_storage_project_service_account" {
    override_during = plan
    defaults = {
      email_address = "service-123456789012@gs-project-accounts.iam.gserviceaccount.com"
    }
  }

  mock_resource "google_service_account" {
    override_during = plan
    defaults = {
      email  = "evp-dev-mock@demo-project-123.iam.gserviceaccount.com"
      member = "serviceAccount:evp-dev-mock@demo-project-123.iam.gserviceaccount.com"
      name   = "projects/demo-project-123/serviceAccounts/evp-dev-mock@demo-project-123.iam.gserviceaccount.com"
    }
  }
}

variables {
  project_id   = "demo-project-123"
  alert_emails = ["oncall@example.com"]
}

run "push_mode_plan" {
  command = plan

  assert {
    condition     = output.raw_bucket == "demo-project-123-evp-dev-raw" && output.curated_bucket == "demo-project-123-evp-dev-curated"
    error_message = "Bucket names must be derived from project, name and environment."
  }

  assert {
    condition     = output.processor_subscription == "evp-dev-raw-object-events-processor" && output.dead_letter_subscription == "evp-dev-raw-object-events-dlq-sub"
    error_message = "Push mode must create the processing and dead-letter subscriptions."
  }

  assert {
    condition     = output.function_name == "evp-dev-processor"
    error_message = "Unexpected function name."
  }

  assert {
    condition     = length(google_project_service.enabled) == 11 && contains(keys(google_project_service.enabled), "eventarc.googleapis.com")
    error_message = "Required APIs must be enabled."
  }

  assert {
    condition     = alltrue([for s in google_project_service.enabled : s.disable_on_destroy == false])
    error_message = "Destroying this stack must not disable shared project APIs."
  }
}

run "eventarc_mode_plan" {
  command = plan

  variables {
    delivery_mode = "eventarc"
  }

  assert {
    condition     = output.processor_subscription == null && output.dead_letter_subscription == null
    error_message = "Eventarc mode must not create the owned push subscription or DLQ."
  }
}

run "with_budget_and_cmek" {
  command = plan

  variables {
    billing_account = "000000-AAAAAA-BBBBBB"
    kms_key_name    = "projects/demo-project-123/locations/europe-west1/keyRings/data/cryptoKeys/evp"
  }

  assert {
    condition     = output.raw_bucket == "demo-project-123-evp-dev-raw"
    error_message = "Optional features must not change naming."
  }
}

run "rejects_invalid_project_id" {
  command = plan

  variables {
    project_id = "Bad_Project"
  }

  expect_failures = [var.project_id]
}

run "rejects_invalid_inputs" {
  command = plan

  variables {
    billing_account       = "not-a-billing-account"
    alert_emails          = ["nobody"]
    max_delivery_attempts = 1
    kms_key_name          = "my-key"
  }

  expect_failures = [
    var.billing_account,
    var.alert_emails,
    var.max_delivery_attempts,
    var.kms_key_name,
  ]
}

