mock_provider "google" {
  mock_data "google_project" {
    defaults = {
      number = "123456789012"
    }
  }

  mock_data "google_storage_project_service_account" {
    defaults = {
      email_address = "service-123456789012@gs-project-accounts.iam.gserviceaccount.com"
    }
  }
}

variables {
  project_id                 = "demo-project"
  name_prefix                = "evp-test"
  raw_bucket_name            = "demo-project-evp-test-raw"
  push_endpoint              = "https://evp-test-processor-abc123-ew.a.run.app"
  push_service_account_email = "evp-test-fn-invoke@demo-project.iam.gserviceaccount.com"
}

run "notification_wiring" {
  command = plan

  assert {
    condition     = google_storage_notification.raw_finalize.event_types == toset(["OBJECT_FINALIZE"])
    error_message = "Only OBJECT_FINALIZE events should be published."
  }

  assert {
    condition     = google_storage_notification.raw_finalize.payload_format == "JSON_API_V1" && google_storage_notification.raw_finalize.object_name_prefix == "incoming/"
    error_message = "Notification must carry the object resource and be limited to the raw prefix."
  }

  assert {
    condition     = google_pubsub_topic_iam_member.gcs_publisher.member == "serviceAccount:service-123456789012@gs-project-accounts.iam.gserviceaccount.com"
    error_message = "The Cloud Storage service agent must be allowed to publish."
  }
}

run "retry_and_dead_letter" {
  command = plan

  assert {
    condition     = google_pubsub_subscription.processor[0].dead_letter_policy[0].max_delivery_attempts == 5
    error_message = "Default max delivery attempts must be 5."
  }

  assert {
    condition     = google_pubsub_subscription.processor[0].retry_policy[0].minimum_backoff == "10s" && google_pubsub_subscription.processor[0].retry_policy[0].maximum_backoff == "600s"
    error_message = "Exponential backoff must be configured between 10s and 600s."
  }

  assert {
    condition     = google_pubsub_subscription.processor[0].push_config[0].oidc_token[0].service_account_email == var.push_service_account_email
    error_message = "Push requests must be authenticated with an OIDC token."
  }

  assert {
    condition     = google_pubsub_subscription.dead_letter[0].message_retention_duration == "604800s"
    error_message = "Dead letters must be retained for 7 days."
  }

  assert {
    condition     = google_pubsub_topic_iam_member.dlq_publisher[0].member == "serviceAccount:service-123456789012@gcp-sa-pubsub.iam.gserviceaccount.com"
    error_message = "Pub/Sub service agent must be able to publish to the DLQ."
  }

  assert {
    condition     = google_pubsub_subscription_iam_member.processor_dlq_subscriber[0].role == "roles/pubsub.subscriber"
    error_message = "Pub/Sub service agent must be able to ack forwarded messages."
  }
}

run "custom_attempts" {
  command = plan

  variables {
    max_delivery_attempts = 20
  }

  assert {
    condition     = google_pubsub_subscription.processor[0].dead_letter_policy[0].max_delivery_attempts == 20
    error_message = "max_delivery_attempts must be passed through."
  }
}

run "rejects_too_few_attempts" {
  command = plan

  variables {
    max_delivery_attempts = 3
  }

  expect_failures = [var.max_delivery_attempts]
}

run "eventarc_mode_has_no_owned_subscription" {
  command = plan

  variables {
    create_push_subscription   = false
    push_endpoint              = null
    push_service_account_email = null
  }

  assert {
    condition     = length(google_pubsub_subscription.processor) == 0 && length(google_pubsub_topic.dead_letter) == 0
    error_message = "No push subscription or DLQ expected when Eventarc consumes the topic."
  }
}

run "push_requires_endpoint" {
  command = plan

  variables {
    push_endpoint = null
  }

  expect_failures = [google_pubsub_subscription.processor]
}
